module rattpack.cli.rattbuild;

import rattpack.cli.options;
import rattpack.spec.loader;
import rattpack.config.environment;
import rattpack.config.profiles;
import rattpack.graph.model;
import rattpack.graph.scheduler;
import rattpack.graph.hash;
import rattpack.plugin.abi;
import rattpack.plugin.loader;
import rattpack.plugin.exporters;
import rattpack.serialization;
import rattpack.diagnostic;
import rattpack.rt.sys;
import rattpack.script.value : Value;
import rattpack.script.evaluator : Evaluator;
import rattpack.script.snapshot : thaw;
import std.stdio;
import std.file;
import std.path;
import std.conv : to;

int run(string[] args)
{
    try
    {
        BuildOptions options;
        auto parsed = parseOptions(options, args);
        if (parsed.isHelpWanted)
            return 0;
        if (!parsed)
            return 2;
        if (options.version_)
        {
            writeln("rattbuild 0.1.0");
            return 0;
        }
        auto root = absolutePath(options.directory);
        WarningSink warningSink = delegate(string code, string message, Location loc) {
            printWarning(code, message, loc);
        };
        auto internalAction = options.positional.length && options.positional[0] == "__run-action";
        auto config = internalAction ? new Configuration(cast(Value[string]) null) : new Configuration(null,
                options.warningsAsErrors, warningSink);
        if (options.listProfiles)
        {
            foreach (name; profileNames(config))
                writeln(name);
            return 0;
        }
        if (options.initializeProject)
        {
            initialize(root, options.profile, config);
            writeln("created " ~ buildPath(root, "Rattspec"));
            return 0;
        }
        auto command = options.positional.length ? options.positional[0] : "build";
        if (command == "__run-action")
        {
            if (!options.graph.length || !options.action.length)
                fail("E_CLI", "__run-action requires --graph and --action");
            auto graph = Graph.importGraph(readText(options.graph));
            if (!(options.action in graph.actions))
                fail("E_TARGET", "unknown frozen action " ~ options.action);
            auto action = graph.actions[options.action];
            if (action.settings.length)
                config = new Configuration(thaw(new Evaluator, action.settings).closure.values);
            auto scheduler = new Scheduler(graph, config, 1);
            scheduler.output = (line) { writeln(line); };
            scheduler.runSingle(action, options.incrementalAction);
            if (options.stamp.length)
                atomicWrite(options.stamp, graph.actions[options.action].id ~ "\n");
            return 0;
        }
        validateBuildCommand(command);
        Graph graph;
        if (options.importPath.length)
            graph = Graph.importGraph(readText(options.importPath));
        else
            graph = new SpecLoader(root, config, options.warningsAsErrors, warningSink).load;
        if (command == "graph")
        {
            auto data = options.dot ? graph.toDot : canonical(graph.toJSON) ~ "\n";
            if (options.output.length)
                atomicWrite(options.output, data);
            else
                write(data);
            return 0;
        }
        if (command == "clean")
        {
            foreach (node; graph.artifacts.byValue)
                if (node.producer.length && exists(absolutePath(node.path, graph.root)))
                    remove(absolutePath(node.path, graph.root));
            auto cache = new Scheduler(graph, config, 1).cacheDirectory;
            if (exists(cache))
                rmdirRecurse(cache);
            auto local = buildPath(graph.root, ".rattpack");
            if (exists(local))
                rmdirRecurse(local);
            return 0;
        }
        if (command == "export")
        {
            if (!options.exporter.length)
                fail("E_CLI", "export requires --to=<cmake|gnumake|ninja|meson|plugin-path>");
            auto destination = options.output.length
                ? absolutePath(options.output) : buildPath(root, "build",
                        "export", options.exporter);
            RattPluginV1 api;
            Plugin plugin;
            if (exists(options.exporter))
            {
                plugin = new Plugin(absolutePath(options.exporter));
                api = *plugin.api;
            }
            else
                api = builtinExporter(options.exporter);
            scope (exit)
                if (plugin !is null)
                    plugin.close;
            if (api.kind != PluginKind.exporter)
                fail("E_PLUGIN_ABI", "plugin is not an exporter");
            string error;
            auto host = thisExePath;
            if (api.exportGraph(canonical(graph.toJSON), destination, host, error))
                fail("E_GRAPH", error);
            writeln("exported " ~ api.name ~ " to " ~ destination);
            return 0;
        }
        auto jobs = options.jobs;
        if (!jobs)
        {
            auto configured = config.get("build.jobs").integer;
            if (configured < 0)
                fail("E_CONFIG", "build.jobs must be nonnegative");
            jobs = cast(size_t) configured;
        }
        auto scheduler = new Scheduler(graph, config, jobs);
        scheduler.dryRun = options.dryRun;
        scheduler.output = (line) { writeln(line); };
        auto result = scheduler.build(options.positional.length > 1
                ? options.positional[1 .. $] : null);
        writeln(result.executed.to!string ~ " built, " ~ result.skipped.to!string ~ " up to date");
        return 0;
    }
    catch (Diagnostic d)
    {
        stderr.writeln(d.msg);
        return 1;
    }
    catch (Exception e)
    {
        stderr.writeln("E_RUNTIME: " ~ e.msg);
        return 1;
    }
}

private void printWarning(string code, string message, Location loc)
{
    stderr.writeln(loc.toString ~ ": " ~ code ~ ": " ~ message);
}

import std.algorithm : canFind;
