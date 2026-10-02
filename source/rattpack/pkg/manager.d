module rattpack.pkg.manager;

import rattpack.pkg.manifest;
import rattpack.pkg.lockfile;
import rattpack.pkg.archive;
import rattpack.native.libraries;
import rattpack.config.environment;
import rattpack.graph.hash;
import rattpack.script.parser;
import rattpack.script.ast;
import rattpack.script.value;
import rattpack.diagnostic;
import rattpack.rt.sys;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array : array;
import std.json;
import std.conv : to;
import requests : Request;
import semver;

private struct Candidate
{
    Dependency dependency;
    string version_;
}

private struct Resolved
{
    LockedPackage locked;
    Dependency[] children;
}

class PackageManager
{
    string root;
    string cache;
    Configuration configuration;
    bool allowFloating;
    void delegate(string) output;
    private Resolved[string] fetched;
    private JSONValue[string] indexes;

    this(string root, Configuration configuration)
    {
        this.root = absolutePath(root);
        this.configuration = configuration;
        cache = buildPath(cacheHome, "rattpack", "pkgs");
    }

    string packagePath(LockedPackage entry)
    {
        return buildPath(cache, entry.name, entry.treeHash);
    }

    Lockfile resolve(bool update = false)
    {
        auto manifest = readManifest(buildPath(root, "Rattpkg"), configuration);
        auto path = buildPath(root, "Rattpkg.lock");
        if (!update && exists(path))
        {
            auto lock = readLock(path);
            if (lock.manifestHash == manifest.fingerprint)
            {
                fetch(lock);
                return lock;
            }
        }
        Dependency[][string] requirements;
        foreach (dep; manifest.dependencies)
            requirements[dep.name] ~= dep;
        Resolved[string] selection;
        if (!solve(requirements, null, selection))
            fail("E_PACKAGE", "dependency constraints have no compatible resolution");
        Lockfile lock;
        lock.project = manifest.name;
        lock.manifestHash = manifest.fingerprint;
        foreach (name; selection.keys.sort)
            lock.entries ~= selection[name].locked;
        writeLock(path, lock);
        return lock;
    }

    private bool accepts(Resolved selected, Dependency[] requirements)
    {
        foreach (dep; requirements)
        {
            if (dep.source == "registry")
            {
                auto range = SemVerRange(dep.constraint);
                auto version_ = SemVer(selected.locked.version_);
                if (!range.isValid)
                    fail("E_PACKAGE", "invalid version constraint: " ~ dep.constraint);
                if (!version_.isValid || !version_.satisfies(range))
                    return false;
            }
            else
            {
                if (dep.source != selected.locked.source || dep.url != selected.locked.url)
                    return false;
                if (materialize(dep).locked.treeHash != selected.locked.treeHash)
                    return false;
            }
        }
        return true;
    }

    private bool solve(Dependency[][string] requirements,
            Resolved[string] chosen, ref Resolved[string] result)
    {
        foreach (name, selected; chosen)
            if (name in requirements && !accepts(selected, requirements[name]))
                return false;
        string next;
        foreach (name; requirements.keys.sort)
            if (!(name in chosen))
            {
                next = name;
                break;
            }
        if (!next.length)
        {
            result = chosen;
            return true;
        }
        foreach (candidate; candidates(requirements[next]))
        {
            auto resolved = materialize(candidate.dependency, candidate.version_);
            if (!accepts(resolved, requirements[next]))
                continue;
            auto newChosen = chosen.dup;
            newChosen[next] = resolved;
            auto newRequirements = requirements.dup;
            foreach (dependency; resolved.children)
                newRequirements[dependency.name] = newRequirements.get(dependency.name,
                        null).dup ~ dependency;
            if (solve(newRequirements, newChosen, result))
                return true;
        }
        return false;
    }

    private Candidate[] candidates(Dependency[] requirements)
    {
        auto dependency = requirements[0];
        if (dependency.source != "registry")
            return [Candidate(dependency, "")];
        auto name = dependency.name;
        if (!(name in indexes))
        {
            string[] registries = [configuration.text("pkg.registry")];
            foreach (mirror; configuration.get("pkg.mirrors", Value(cast(Value[])[
                ])).items)
                registries ~= mirror.text;
            Exception last;
            foreach (registry; registries)
            {
                try
                {
                    indexes[name] = parseJSON(cast(string) download(
                            registry.stripRight("/") ~ "/" ~ name ~ "/index.json"));
                    break;
                }
                catch (Exception e)
                {
                    last = e;
                }
            }
            if (!(name in indexes))
                fail("E_PACKAGE", "registry lookup failed for " ~ name ~ ": " ~ (last is null
                        ? "no registry" : last.msg));
        }
        Candidate[] result;
        foreach (entry; indexes[name]["versions"].array)
        {
            auto version_ = SemVer(entry["version"].str);
            bool accepted = version_.isValid;
            foreach (dep; requirements)
            {
                if (dep.source != "registry")
                    accepted = false;
                auto range = SemVerRange(dep.constraint);
                if (!range.isValid)
                    fail("E_PACKAGE", "invalid version range: " ~ dep.constraint);
                if (!version_.satisfies(range))
                    accepted = false;
            }
            if (!accepted)
                continue;
            auto dep = dependency;
            dep.source = "http";
            dep.url = entry["url"].str;
            dep.checksum = entry["sha256"].str;
            result ~= Candidate(dep, entry["version"].str);
        }
        result.sort!((a, b) => SemVer(a.version_) > SemVer(b.version_));
        return result;
    }

    private Resolved materialize(Dependency dep, string selectedVersion = "")
    {
        auto key = hashParts([
            dep.name, dep.source, dep.url, dep.tag, dep.revision, dep.branch,
            dep.checksum, selectedVersion
        ]);
        if (auto value = key in fetched)
            return *value;
        if (dep.branch.length && !allowFloating)
            fail("E_FLOATING", "branch dependencies require --allow-floating: " ~ dep.name);
        import std.random : uniform;

        auto work = buildPath(cacheHome, "rattpack", "tmp",
                dep.name ~ "-" ~ uniform(0UL, ulong.max).to!string);
        mkdirRecurse(work);
        scope (exit)
            if (exists(work))
                rmdirRecurse(work);
        auto tree = buildPath(work, "tree");
        LockedPackage entry;
        entry.name = dep.name;
        entry.source = dep.source;
        entry.url = dep.url;
        entry.checksum = dep.checksum;
        if (output !is null)
            output("resolve " ~ dep.name);
        if (dep.source == "git")
        {
            auto revision = dep.revision.length ? dep.revision : dep.tag.length
                ? "refs/tags/" ~ dep.tag : "refs/remotes/origin/" ~ dep.branch;
            entry.revision = gitCheckout(dep.url, tree, revision);
            if (exists(buildPath(tree, ".git")))
                rmdirRecurse(buildPath(tree, ".git"));
        }
        else
        {
            auto bytes = download(dep.url);
            if (dep.checksum.length != 64 || sha256(bytes) != dep.checksum.toLower)
                fail("E_CHECKSUM", "archive checksum mismatch: " ~ dep.name);
            extractArchive(bytes, tree);
            string[] roots;
            foreach (child; dirEntries(tree, SpanMode.shallow))
                roots ~= child.name;
            if (roots.length == 1 && isDir(roots[0]))
                tree = roots[0];
        }
        Resolved resolved;
        entry.version_ = selectedVersion;
        if (exists(buildPath(tree, "Rattpkg")))
        {
            auto manifest = readManifest(buildPath(tree, "Rattpkg"), configuration);
            entry.identity = "package";
            if (!entry.version_.length)
                entry.version_ = manifest.version_;
            if (selectedVersion.length && selectedVersion != manifest.version_)
                fail("E_PACKAGE", "registry version disagrees with manifest: " ~ dep.name);
            resolved.children = manifest.dependencies;
        }
        else if (exists(buildPath(tree, "Rattspec")))
        {
            entry.identity = "project";
            auto ast = new Parser(readText(buildPath(tree, "Rattspec"))).parse;
            foreach (statement; ast.statements)
                if (statement.kind == StmtKind.expression && statement.expression.kind == ExprKind.call
                        && statement.expression.left.text == "project")
                    foreach (i, expression; statement.expression.entries)
                        if (statement.expression.names[i] == "version"
                                && expression.kind == ExprKind.literal)
                            entry.version_ = expression.literal.text;
        }
        else
            entry.identity = "source";
        if (!entry.version_.length)
            entry.version_ = dep.tag.length ? dep.tag : entry.revision.length
                ? entry.revision : "0.0.0";
        entry.treeHash = hashTree(tree);
        entry.dependencies = resolved.children.map!(d => d.name).array;
        entry.dependencies.sort;
        auto destination = packagePath(entry);
        if (exists(destination))
        {
            if (hashTree(destination) != entry.treeHash)
                fail("E_CHECKSUM", "cached package was modified: " ~ dep.name);
        }
        else
        {
            mkdirRecurse(dirName(destination));
            rename(tree, destination);
        }
        resolved.locked = entry;
        fetched[key] = resolved;
        return resolved;
    }

    void fetch(Lockfile lock)
    {
        foreach (entry; lock.entries)
        {
            auto path = packagePath(entry);
            if (exists(path))
            {
                if (hashTree(path) != entry.treeHash)
                    fail("E_CHECKSUM", "cached package was modified: " ~ entry.name);
                continue;
            }
            Dependency dep;
            dep.name = entry.name;
            dep.source = entry.source;
            dep.url = entry.url;
            dep.revision = entry.revision;
            dep.checksum = entry.checksum;
            auto result = materialize(dep, entry.version_);
            if (result.locked.treeHash != entry.treeHash)
                fail("E_CHECKSUM", "fetched tree disagrees with lockfile: " ~ entry.name);
        }
    }

    void verify(Lockfile lock)
    {
        foreach (entry; lock.entries)
            if (!exists(packagePath(entry)) || hashTree(packagePath(entry)) != entry.treeHash)
                fail("E_CHECKSUM", "verification failed: " ~ entry.name);
    }
}

ubyte[] download(string url)
{
    if (url.startsWith("file://"))
        return cast(ubyte[]) read(url[7 .. $]);
    try
    {
        auto request = Request();
        auto response = request.get(url);
        if (response.code >= 400)
            fail("E_PACKAGE", "download returned status " ~ response.code.to!string ~ ": " ~ url);
        return response.responseBody.data.dup;
    }
    catch (Diagnostic d)
    {
        throw d;
    }
    catch (Exception e)
    {
        fail("E_PACKAGE", "download failed: " ~ e.msg);
    }
    return null;
}
