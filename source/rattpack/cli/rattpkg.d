module rattpack.cli.rattpkg;

import rattpack.cli.options;
import rattpack.pkg.manager;
import rattpack.pkg.lockfile;
import rattpack.config.environment;
import rattpack.diagnostic;
import std.path;
import std.stdio;

int run(string[] args)
{
    try
    {
        PackageOptions options;
        auto parsed = parseOptions(options, args);
        if (parsed.isHelpWanted)
            return 0;
        if (!parsed)
            return 2;
        if (options.version_)
        {
            writeln("rattpkg 0.1.0");
            return 0;
        }
        if (options.positional.length != 1)
            fail("E_CLI",
                    "usage: rattpkg <resolve|fetch|verify> [--allow-floating] [--update] [-C DIRECTORY]");
        auto root = absolutePath(options.directory);
        auto manager = new PackageManager(root, new Configuration);
        manager.allowFloating = options.allowFloating;
        manager.output = (line) { writeln(line); };
        switch (options.positional[0])
        {
        case "resolve":
            manager.resolve(options.update);
            writeln("resolved Rattpkg.lock");
            break;
        case "fetch":
            manager.fetch(readLock(buildPath(root, "Rattpkg.lock")));
            writeln("packages fetched");
            break;
        case "verify":
            manager.verify(readLock(buildPath(root, "Rattpkg.lock")));
            writeln("packages verified");
            break;
        default:
            fail("E_CLI", "unknown package command " ~ options.positional[0]);
        }
        return 0;
    }
    catch (Diagnostic d)
    {
        stderr.writeln(d.msg);
        return 1;
    }
    catch (Exception e)
    {
        stderr.writeln("E_PACKAGE: " ~ e.msg);
        return 1;
    }
}
