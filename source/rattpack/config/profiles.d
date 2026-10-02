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

void initialize(string root, string profile, Configuration config)
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
    if (exists(output))
        fail("E_SPEC", "Rattspec already exists");
    auto name = baseName(absolutePath(root));
    Value[string] extra = [
        "cwd": Value.path(absolutePath(root)), "dirname": Value(name),
        "user": Value(config.text("user.name", userName)),
        "date": Value(Clock.currTime.toISOExtString[0 .. 10])
    ];
    atomicWrite(output, preprocess(readText(path), config, extra, path));
}
