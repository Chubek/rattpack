module rattpack.cli.rattspec;

import rattpack.cli.options;
import rattpack.config.tool;
import rattpack.diagnostic : Diagnostic, Location, fail;
import rattpack.dirmap;
import rattpack.plugin.abi : PluginKind;
import rattpack.plugin.loader : Plugin;
import rattpack.rt.sys : cacheHome, configHome, sharedSuffix;
import rattpack.script.evaluator : Evaluator, Phase;
import rattpack.script.value : Arguments, Value;
import rattpack.spec.assist;
import std.conv : to;
import std.file : exists, thisExePath;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.stdio : stderr, writeln, write;
import std.algorithm : any;
import std.string : join, startsWith, strip;

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
        if (!options.positional.length)
            fail("E_CLI", "usage: rattspec assist REQUEST | rattspec map DIRECTORY");
        switch (options.positional[0])
        {
        case "assist":
            return assist(options, args, options.positional[1 .. $]);
        case "map":
            return map(options, options.positional[1 .. $]);
        default:
            fail("E_CLI", "unknown command " ~ options.positional[0]
                    ~ "; use assist or map");
        }
        return 2;
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

/// Generate and publish validated Rattspec and Rattpkg files.
private int assist(SpecOptions options, string[] argv, string[] request)
{
    if (!request.length || !request.join(" ").strip.length)
        fail("E_CLI", "usage: rattspec assist REQUEST [--opencode|--openai]");
    auto tool = loadToolConfig(toolConfigDirectory());
    auto backend = selectBackend(options, tool);
    auto project = readAssistProject(options.directory);
    auto prompt = project.prompt(request.join(" "), mapContext(options, tool));
    auto plugin = new Plugin(pluginPath(options, tool, backend));
    scope (exit)
        plugin.close;
    if (plugin.api.kind != PluginKind.stdlib)
        fail("E_PLUGIN_ABI", backendName(backend)
                ~ " assist needs a stdlib plugin providing generate()");
    auto evaluator = new Evaluator(Phase.standalone, project.root);
    plugin.api.registerModules(evaluator);
    auto response = evaluator.invoke(generate(evaluator, backend),
            callArguments(options, argv, tool, backend, prompt), Location("<assist>"));
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
                writeln((project.files[name].present ? "updated " : "created ")
                        ~ buildPath(project.root, name));
    if (proposal.summary.length)
        writeln(proposal.summary);
    return 0;
}

/// Scan a directory into a cached binary map and optionally render its text.
private int map(SpecOptions options, string[] target)
{
    if (target.length > 1)
        fail("E_CLI", "usage: rattspec map DIRECTORY");
    auto tool = loadToolConfig(toolConfigDirectory());
    auto directory = target.length ? target[0] : options.directory;
    auto scanned = scanDirectory(directory);
    auto destination = options.mapOut.length ? absolutePath(options.mapOut)
            : buildPath(cacheHome(), "rattpack", baseName(scanned.root.length
                    ? directory : directory) ~ ".bin");
    writeDirMap(destination, scanned);
    writeln(scanned.nodes.length.to!string ~ " entries, "
            ~ scanned.totalBytes.to!string ~ " bytes -> " ~ destination);
    if (options.printMap)
        write(renderDirMap(scanned, options.summary && tool.map.summary));
    return 0;
}

/// The module a plugin registers for this backend.
private string backendName(AssistBackend backend) @safe
{
    return cast(string) backend;
}

/// Rattpack keeps its configuration in a rattpack/ directory beneath the XDG
/// configuration home, matching Config.toml and the profile directory.
private string toolConfigDirectory()
{
    return buildPath(configHome(), "rattpack");
}

/// Choose the backend from flags, then the configuration file.
private AssistBackend selectBackend(SpecOptions options, ToolConfig tool) @safe
{
    if (options.useOpenCode && options.useOpenAi)
        fail("E_CLI", "--opencode and --openai are mutually exclusive");
    if (options.useOpenCode)
        return AssistBackend.opencode;
    if (options.useOpenAi)
        return AssistBackend.openai;
    return tool.backend;
}

/// Locate the backend plugin: an explicit path, a configured override, or the
/// shipped default beside this executable.
private string pluginPath(SpecOptions options, ToolConfig tool, AssistBackend backend)
{
    if (options.plugin.length)
        return absolutePath(options.plugin);
    auto name = backend == AssistBackend.openai ? "openai-assist" : "opencode-assist";
    if (auto configured = name in tool.plugins)
        if (configured.length)
            return absolutePath(*configured);
    auto path = buildPath(dirName(thisExePath), "plugins", name ~ sharedSuffix);
    if (!exists(path))
        fail("E_PLUGIN_ABI", name ~ " plugin not found: " ~ path
                ~ "; build it with tools/dogfood.py plugins or select --plugin PATH");
    return path;
}

/// Look up backend.generate in the module the plugin registered.
private Value generate(Evaluator evaluator, AssistBackend backend)
{
    auto module_ = backendName(backend) in evaluator.modules;
    if (module_ is null || module_.kind != Value.Kind.map)
        fail("E_PLUGIN_ABI", "plugin did not register the "
                ~ backendName(backend) ~ " module");
    auto entry = "generate" in module_.data.mapValue.values;
    if (entry is null)
        fail("E_PLUGIN_ABI", "plugin did not register "
                ~ backendName(backend) ~ ".generate");
    return *entry;
}

/// Build the native call, resolving credentials from flags, the environment, and
/// the configuration file, in that order.
private Arguments callArguments(SpecOptions options, string[] argv, ToolConfig tool,
        AssistBackend backend, string prompt)
{
    Arguments arguments;
    arguments.named = ["prompt": Value(prompt)];
    // A timeout of zero means "not supplied"; the resolver falls through.
    auto timeout = options.timeout ? options.timeout.to!string : "";
    if (backend == AssistBackend.openai)
    {
        arguments.named["base_url"] = Value(resolveSetting(options.openaiUrl,
                ["OPENAI_BASE", "OPENAI_API_BASE", "RATTPACK_OPENAI_URL"],
                tool.openai.baseUrl, ""));
        arguments.named["api_key"] = Value(resolveSetting(options.openaiKey,
                ["OPENAI_API_KEY", "RATTPACK_OPENAI_KEY"], tool.openai.apiKey, ""));
        arguments.named["user"] = Value(resolveSetting(options.openaiUser,
                ["RATTPACK_OPENAI_USER", "OPENAI_USER"], tool.openai.user, ""));
        arguments.named["password"] = Value(resolveSetting(options.openaiPassword,
                ["RATTPACK_OPENAI_PASSWORD", "OPENAI_PASSWORD"], tool.openai.password, ""));
        arguments.named["organization"] = Value(resolveSetting("",
                ["OPENAI_ORG_ID"], tool.openai.organization, ""));
        arguments.named["project"] = Value(resolveSetting("",
                ["OPENAI_PROJECT_ID"], tool.openai.project, ""));
        arguments.named["model"] = Value(resolveSetting(options.model,
                ["OPENAI_MODEL", "RATTPACK_OPENAI_MODEL"], tool.openai.model, ""));
        arguments.named["api"] = Value(resolveSetting(options.openaiApi,
                ["RATTPACK_OPENAI_API"], tool.openai.api, "chat"));
        arguments.named["timeout"] = Value(cast(long) resolveTimeout(timeout,
                ["RATTPACK_OPENAI_TIMEOUT"], tool.openai.timeout));
        return arguments;
    }
    arguments.named["executable"] = Value(resolveSetting(options.opencodeExecutable,
            ["RATTPACK_OPENCODE", "OPENCODE"], tool.opencode.executable, "opencode"));
    arguments.named["server"] = Value(resolveSetting(options.server,
            ["RATTPACK_OPENCODE_SERVER"], tool.opencode.server, ""));
    arguments.named["model"] = Value(resolveSetting(options.model,
            ["RATTPACK_OPENCODE_MODEL", "OPENCODE_MODEL"], tool.opencode.model, ""));
    // argparse cannot report whether a defaulted boolean was given, so an
    // explicit --standalone/--no-standalone in argv is detected directly.
    auto explicitStandalone = argv.any!(a => a == "--standalone"
            || a == "--no-standalone" || a.startsWith("--standalone=")
            || a.startsWith("--no-standalone="));
    arguments.named["standalone"] = Value(explicitStandalone
            ? resolveFlag(options.standalone ? "true" : "false", null, true)
            : resolveFlag("", ["RATTPACK_OPENCODE_STANDALONE"], tool.opencode.standalone));
    arguments.named["timeout"] = Value(cast(long) resolveTimeout(timeout,
            ["RATTPACK_OPENCODE_TIMEOUT"], tool.opencode.timeout));
    return arguments;
}

/// Directory map text appended to the prompt when a map already exists.
///
/// `rattspec map` writes the cache; assist reuses it so a large project is sent
/// as one compact inventory instead of a long path list.
private string mapContext(SpecOptions options, ToolConfig tool)
{
    auto path = dirMapCachePath(options.directory);
    if (!exists(path))
        return "";
    auto mapped = MappedDirMap.open(path);
    scope (exit)
        mapped.close;
    return "\nProject map (terse directory map DSL):\n"
            ~ renderMappedDirMap(mapped, options.summary && tool.map.summary);
}