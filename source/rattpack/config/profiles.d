module rattpack.config.profiles;

import rattpack.config.environment;
import rattpack.config.templating;
import rattpack.script.value;
import rattpack.rt.sys;
import rattpack.diagnostic;
import std.file;
import std.path;
import std.algorithm;
import std.array : array;
import std.datetime.systime : Clock;
import std.json : JSONValue;

enum string[string] shippedProfiles = [
    "c-exe": import("c-exe.in"), "c-lib": import("c-lib.in"),
    "cxx-exe": import("cxx-exe.in"), "cxx-lib": import("cxx-lib.in"),
    "d-exe": import("d-exe.in"), "d-lib": import("d-lib.in"),
    "monorepo": import("monorepo.in"), "empty": import("empty.in")
];

void installProfiles(Configuration config)
{
    auto directory = buildPath(config.directory, "buildprof");
    mkdirRecurse(directory);
    foreach (name; shippedProfiles.keys.sort)
    {
        auto path = buildPath(directory, name ~ ".in");
        if (!exists(path))
            atomicWrite(path, shippedProfiles[name]);
    }
}

string[] profileNames(Configuration config)
{
    installProfiles(config);
    string[] names;
    foreach (path; sortedFiles(buildPath(config.directory, "buildprof"), false))
        if (extension(path) == ".in")
            names ~= stripExtension(baseName(path));
    names.sort;
    return names;
}

void initialize(string root, string profile, Configuration config, bool scaffold = false)
{
    installProfiles(config);
    if (!profile.length)
        profile = "empty";
    if (profile.canFind('/') || profile.canFind('\\') || profile == "." || profile == "..")
        fail("E_TEMPLATE", "invalid profile name");
    auto path = buildPath(config.directory, "buildprof", profile ~ ".in");
    if (!exists(path))
        fail("E_TEMPLATE", "profile not found: " ~ profile);
    auto output = buildPath(root, "Rattspec");
    if (exists(output) || exists(buildPath(root, "Rattspec.in")))
        fail("E_SPEC", "Rattspec or Rattspec.in already exists");
    auto name = baseName(absolutePath(root));
    Value[string] extra = [
        "cwd": Value.path(absolutePath(root)), "dirname": Value(name),
        "user": Value(config.text("user.name", userName)),
        "date": Value(Clock.currTime.toISOExtString[0 .. 10]),
        "dirname_literal": Value(JSONValue(name).toString),
        "welcome_literal": Value(JSONValue(name ~ "\n").toString),
        "license_literal": Value(JSONValue(config.text("user.license", "MIT")).toString)
    ];
    string[string] files;
    files["Rattspec"] = preprocess(readText(path), config, extra, path);
    if (scaffold)
    {
        if (!(profile in shippedProfiles))
            fail("E_TEMPLATE", "--scaffold requires a shipped profile");
        files["Rattpkg"] = preprocess(import("Rattpkg.in"), config, extra);
        files["README.md"] = preprocess(import("README.md.in"), config, extra);
        files[".gitignore"] = import("gitignore");
        switch (profile)
        {
        case "c-exe":
            files["src/main.c"] = import("c-exe.c");
            break;
        case "cxx-exe":
            files["src/main.cpp"] = import("cxx-exe.cpp");
            break;
        case "d-exe":
            files["src/main.d"] = import("d-exe.d");
            break;
        case "c-lib":
            files["src/starter.c"] = import("c-lib.c");
            break;
        case "cxx-lib":
            files["src/starter.cpp"] = import("cxx-lib.cpp");
            break;
        case "d-lib":
            files["src/starter.d"] = import("d-lib.d");
            break;
        default:
            break;
        }
        if (profile.endsWith("-lib"))
            files[".gitignore"] ~= "/Rattpkg.lock\n";
    }
    // Render and check the entire plan before writing any project files.
    foreach (relative; files.keys.sort)
    {
        auto destination = buildPath(root, relative);
        if (exists(destination))
            fail("E_SPEC", "initialization would overwrite " ~ relative);
        auto parent = dirName(destination);
        while (!exists(parent) && parent != dirName(parent))
            parent = dirName(parent);
        if (exists(parent) && !isDir(parent))
            fail("E_SPEC", "initialization requires a directory: " ~ parent);
    }
    string[] written;
    scope (failure)
        foreach (destination; written)
            if (exists(destination))
                remove(destination);
    // Publish the root spec last so an interrupted scaffold is not buildable.
    foreach (relative; files.keys.sort)
        if (relative != "Rattspec")
        {
            auto destination = buildPath(root, relative);
            atomicWrite(destination, files[relative]);
            written ~= destination;
        }
    atomicWrite(output, files["Rattspec"]);
}
