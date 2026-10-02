module rattpack.pkg.manifest;

import rattpack.script.evaluator;
import rattpack.script.value;
import rattpack.stdlib.modules;
import rattpack.config.environment;
import rattpack.config.templating;
import rattpack.graph.hash;
import rattpack.diagnostic;
import std.file;
import std.path;
import std.algorithm;
import std.string;

struct Dependency
{
    string name;
    string source;
    string url;
    string constraint;
    string tag;
    string revision;
    string branch;
    string checksum;
}

struct Manifest
{
    string name;
    string version_;
    string license;
    string fingerprint;
    Dependency[] dependencies;
}

Manifest readManifest(string path, Configuration configuration)
{
    if (!exists(path))
        fail("E_PACKAGE", "manifest not found: " ~ path);
    auto evaluator = new Evaluator(Phase.construction, dirName(absolutePath(path)));
    installStdlib(evaluator, configuration);
    Manifest manifest;
    evaluator.bind("package", (a, l) {
        if (manifest.name.length)
            fail("E_PACKAGE", "duplicate package declaration", l);
        manifest.name = a.get("name", 0).text(l);
        manifest.version_ = a.get("version", 1).text(l);
        manifest.license = a.get("license", 2, Value("MIT")).text(l);
        validatePackageName(manifest.name, l);
        return Value.handle(Value.Kind.pkg, manifest.name);
    });
    evaluator.globals.values["registry"] = Value([
        "source": Value("registry"),
        "url": Value("")
    ]);
    void bindSource(string kind)
    {
        evaluator.bind(kind, (a, l) => Value([
            "source": Value(kind),
            "url": a.get("url", 0)
        ]));
    }

    foreach (source; ["git", "http", "ftp"])
        bindSource(source);
    evaluator.bind("dep", (a, l) {
        Dependency dep;
        dep.name = a.get("name", 0).text(l);
        validatePackageName(dep.name, l);
        auto source = a.get("from", 1);
        if (source.kind != Value.Kind.map)
            fail("E_PACKAGE", "dep requires from: registry, git(), http(), or ftp()", l);
        dep.source = source.data.mapValue.values.get("source", Value("")).text(l);
        dep.url = source.data.mapValue.values.get("url", Value("")).text(l);
        dep.constraint = a.get("version", 2, Value("*")).text(l);
        dep.tag = a.get("tag", 3, Value("")).text(l);
        dep.revision = a.get("rev", 4, Value("")).text(l);
        dep.branch = a.get("branch", 5, Value("")).text(l);
        dep.checksum = a.get("sha256", 6, Value("")).text(l).toLower;
        if (dep.source == "http" || dep.source == "ftp")
        {
            if (dep.checksum.length != 64 || !dep.checksum.all!(c => "0123456789abcdef".canFind(c)))
                fail("E_CHECKSUM", "HTTP/FTP dependencies require a 64-digit sha256", l);
        }
        else if (dep.source == "git")
        {
            auto pins = (dep.tag.length != 0) + (dep.revision.length != 0) + (dep.branch.length != 0);
            if (pins != 1)
                fail("E_PACKAGE", "git dependency requires exactly one tag, rev, or branch", l);
        }
        else if (dep.source != "registry")
            fail("E_PACKAGE", "invalid dependency source", l);
        foreach (other; manifest.dependencies)
            if (other.name == dep.name)
                fail("E_PACKAGE", "duplicate dependency " ~ dep.name, l);
        manifest.dependencies ~= dep;
        return Value.init;
    });
    auto source = readText(path);
    evaluator.run(source, absolutePath(path));
    if (!manifest.name.length)
        fail("E_PACKAGE", "Rattpkg must call package()", Location(path));
    manifest.dependencies.sort!((a, b) => a.name < b.name);
    string[] parts = [
        source, manifest.name, manifest.version_, manifest.license
    ];
    foreach (dep; manifest.dependencies)
        parts ~= [
        dep.name, dep.source, dep.url, dep.constraint, dep.tag, dep.revision,
        dep.branch, dep.checksum
    ];
    manifest.fingerprint = hashParts(parts);
    return manifest;
}

void validatePackageName(string name, Location loc = Location.init) @safe
{
    if (!name.length || name == "." || name == ".." || !name.all!(c => (c >= 'a'
            && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '_' || c == '-' || c == '.'))
        fail("E_PACKAGE", "invalid package name '" ~ name ~ "'", loc);
}
