module rattpack.cli.rattsc;

import rattpack.script.evaluator;
import rattpack.script.parser;
import rattpack.script.lint;
import rattpack.stdlib.modules;
import rattpack.diagnostic;
import rattpack.rt.sys;
import rattpack.cli.options;
import std.stdio;
import std.file;
import std.path;
import std.string;

int run(string[] args)
{
    try
    {
        ScriptOptions options;
        auto parsed = parseOptions(options, args);
        if (parsed.isHelpWanted)
            return 0;
        if (!parsed)
            return 2;
        if (options.version_)
        {
            writeln("rattsc 0.1.0");
            return 0;
        }
        if (options.testDirectory.length)
            return goldenTests(options.testDirectory);
        auto evaluator = new Evaluator;
        installStdlib(evaluator);
        evaluator.output = (text) { writeln(text); };
        if (options.lint && options.positional.length == 1)
        {
            evaluator.cwd = dirName(absolutePath(options.positional[0]));
            lintFile(options.positional[0], evaluator.sourceTransform);
            return 0;
        }
        if (options.script.length)
        {
            evaluator.run(options.script);
            return 0;
        }
        if (options.positional.length == 1 && !options.lint)
        {
            auto file = absolutePath(options.positional[0]);
            evaluator.cwd = dirName(file);
            evaluator.run(readText(file), file);
            return 0;
        }
        if (args.length)
            fail("E_CLI", "usage: rattsc [--lint FILE | --test DIRECTORY | FILE | -e SCRIPT]");
        string input;
        size_t depth;
        while (true)
        {
            write(depth ? "... " : "ratt> ");
            stdout.flush;
            auto line = stdin.readln;
            if (!line.length)
                break;
            if (!depth && (line.strip == ":quit" || line.strip == ":q"))
                break;
            input ~= line;
            foreach (c; line)
            {
                if (c == '{')
                    depth++;
                if (c == '}' && depth)
                    depth--;
            }
            if (depth)
                continue;
            try
            {
                auto value = evaluator.run(input, "<repl>");
                if (value.kind != value.Kind.nil)
                    writeln(value.str);
            }
            catch (Diagnostic d)
            {
                stderr.writeln(d.msg);
            }
            input = "";
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
        stderr.writeln("E_RUNTIME: " ~ e.msg);
        return 1;
    }
}

int goldenTests(string directory)
{
    size_t total, failures;
    foreach (file; sortedFiles(directory))
    {
        if (!file.endsWith(".ratt"))
            continue;
        total++;
        string actual;
        auto source = readText(file);
        auto evaluator = new Evaluator(source.startsWith("# phase: construction")
                ? Phase.construction : Phase.standalone, dirName(absolutePath(file)));
        installStdlib(evaluator);
        evaluator.output = (text) { actual ~= text ~ "\n"; };
        try
        {
            if (source.startsWith("# lint"))
                lint(new Parser(source, absolutePath(file)).parse);
            else if (source.startsWith("# test:"))
                diagnosticScenario(source, file, (line) { actual ~= line ~ "\n"; });
            else
                evaluator.run(source, absolutePath(file));
        }
        catch (Diagnostic d)
        {
            actual ~= d.code ~ "\n";
        }
        auto expectedPath = stripExtension(file) ~ ".expected";
        if (!exists(expectedPath) || actual != readText(expectedPath))
        {
            failures++;
            stderr.writeln("FAIL " ~ file ~ "\n  actual: " ~ actual);
        }
    }
    import std.conv : to;

    writeln((total - failures).to!string ~ "/" ~ total.to!string ~ " script tests passed");
    return failures || !total ? 1 : 0;
}

private void diagnosticScenario(string source, string file, void delegate(string) output)
{
    import rattpack.config.environment;
    import rattpack.config.templating;
    import rattpack.spec.loader;
    import rattpack.pkg.manifest;
    import rattpack.pkg.manager;
    import rattpack.graph.model;
    import rattpack.graph.scheduler;
    import rattpack.plugin.loader;
    import std.random : uniform;
    import std.conv : to;

    auto scenario = source.splitLines[0][7 .. $].strip;
    auto root = buildPath(exists("/tmp/opencode") ? "/tmp/opencode" : tempDir,
            "rattpack-golden-" ~ uniform(0UL, ulong.max).to!string);
    mkdirRecurse(root);
    scope (exit)
        rmdirRecurse(root);
    auto config = new Configuration(buildPath(root, "config"));
    switch (scenario)
    {
    case "spec":
    case "build":
    case "hermetic":
    case "identity":
    case "nested":
        auto identitySpec = "project(name: \"root\", version: \"1.0.0\", kind: \"single\")\n"
            ~ "rule(name: \"ok\", output: \"build/ok\", command: [\"true\"])";
        atomicWrite(buildPath(root, "Rattspec"), scenario == "identity" ? identitySpec : source);
        if (scenario == "identity")
            atomicWrite(buildPath(root, "child", "Rattspec.m"), source);
        if (scenario == "nested")
            atomicWrite(buildPath(root, "child", "Rattspec"),
                    "project(name: \"nested\", version: \"1.0.0\", kind: \"single\")\n"
                    ~ "rule(name: \"child\", output: \"build/child\", command: [\"true\"])");
        auto graph = new SpecLoader(root, config, scenario == "nested").load;
        if (scenario == "build" || scenario == "hermetic")
        {
            auto scheduler = new Scheduler(graph, config, 1);
            scheduler.hermetic = scenario == "hermetic";
            scheduler.build;
        }
        break;
    case "manifest":
    case "floating":
        atomicWrite(buildPath(root, "Rattpkg"), source);
        if (scenario == "floating")
            new PackageManager(root, config).resolve;
        else
            readManifest(buildPath(root, "Rattpkg"), config);
        break;
    case "config":
        atomicWrite(buildPath(root, "config", "Config.toml"), source);
        new Configuration(buildPath(root, "config"));
        break;
    case "dual-config":
        atomicWrite(buildPath(root, "config", "Config.toml"), "[user]\nname = \"toml\"\n");
        atomicWrite(buildPath(root, "config", "Config.yaml"), "user:\n  name: yaml\n");
        new Configuration(buildPath(root, "config"), true);
        break;
    case "template":
        output(preprocess(source[source.indexOf('\n') + 1 .. $], config));
        break;
    case "graph":
        Graph.importGraph(source);
        break;
    case "plugin":
        new Plugin(absolutePath(file));
        break;
    case "cli":
        validateBuildCommand("unknown-command");
        break;
    default:
        fail("E_RUNTIME", "unknown golden scenario: " ~ scenario);
    }
}
