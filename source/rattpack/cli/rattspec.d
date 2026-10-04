module rattpack.cli.rattspec;

import rattpack.cli.options;
import rattpack.diagnostic : Diagnostic, Location, fail;
import rattpack.plugin.abi : PluginKind;
import rattpack.plugin.loader : Plugin;
import rattpack.rt.sys : sharedSuffix;
import rattpack.script.evaluator : Evaluator, Phase;
import rattpack.script.value : Arguments, Value;
import rattpack.spec.assist;
import std.file : exists, thisExePath;
import std.path : absolutePath, buildPath, dirName;
import std.stdio : stderr, writeln;
import std.string : join, strip;

int run(string[] args)
{
    try
    {
        SpecOptions options;
        auto parsed = parseOptions(options, args);
        if (parsed.isHelpWanted)
            return 0;
        if (!parsed)
            return 2;
        if (options.version_)
        {
            writeln("rattspec 0.1.0");
            return 0;
        }
        if (options.positional.length < 2 || options.positional[0] != "assist"
                || !options.positional[1 .. $].join(" ").strip.length)
            fail("E_CLI", "usage: rattspec assist 'REQUEST' [-C DIRECTORY] [--dry-run]");
        if (!options.timeout || options.timeout > int.max)
            fail("E_CLI", "--timeout must be a positive number of seconds");
        auto project = readAssistProject(options.directory);
        auto path = options.plugin.length ? absolutePath(options.plugin) : buildPath(
                dirName(thisExePath), "plugins", "opencode-assist" ~ sharedSuffix);
        if (!exists(path))
            fail("E_PLUGIN_ABI", "opencode-assist plugin not found: " ~ path
                    ~ "; build it with tools/dogfood.py plugins or select --plugin PATH");
        auto plugin = new Plugin(path);
        scope (exit)
            plugin.close;
        if (plugin.api.kind != PluginKind.stdlib)
            fail("E_PLUGIN_ABI", "assist needs a stdlib plugin providing opencode.generate");
        auto evaluator = new Evaluator(Phase.standalone, project.root);
        plugin.api.registerModules(evaluator);
        auto module_ = "opencode" in evaluator.modules;
        if (module_ is null || module_.kind != Value.Kind.map)
            fail("E_PLUGIN_ABI", "assist plugin did not register the opencode module");
        auto generate = "generate" in module_.data.mapValue.values;
        if (generate is null)
            fail("E_PLUGIN_ABI", "assist plugin did not register opencode.generate");
        Arguments arguments;
        arguments.named = [
            "prompt": Value(project.prompt(options.positional[1 .. $].join(" "))),
            "model": Value(options.model),
            "server": Value(options.server),
            "executable": Value(options.opencode),
            "timeout": Value(cast(long) options.timeout)
        ];
        auto response = evaluator.invoke(*generate, arguments, Location("<assist>"));
        auto proposal = decodeAssistProposal(response.text, project);
        if (options.dryRun)
        {
            writeln(proposal.toJSON.toPrettyString);
            return 0;
        }
        applyAssistProposal(project, proposal);
        foreach (name; ["Rattspec", "Rattpkg"])
            if (auto contents = name in proposal.files)
                if (!project.files[name].present || project.files[name].contents != *contents)
                    writeln((project.files[name].present
                            ? "updated " : "created ") ~ buildPath(project.root, name));
        if (proposal.summary.length)
            writeln(proposal.summary);
        return 0;
    }
    catch (Diagnostic diagnostic)
    {
        stderr.writeln(diagnostic.msg);
        return 1;
    }
    catch (Exception error)
    {
        stderr.writeln("E_ASSIST: " ~ error.msg);
        return 1;
    }
}
