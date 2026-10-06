module rattpack.cli.options;

import argparse;
import rattpack.diagnostic;
import std.algorithm : canFind;

/// Options accepted by the build-system CLI.
@(Command("rattbuild").Description("Construct, execute, or export a Rattscript build graph.")
        .Epilog("Commands: build [TARGET ...] (default), graph, export, clean.\n"
            ~ "Examples: rattbuild build -j 8; rattbuild graph --dot; rattbuild export --to=ninja"))
struct BuildOptions
{
    /// Command and optional selected targets.
    @(PositionalArgument.Optional.Description("Command followed by optional target names")) string[] positional;
    /// Project root directory.
    @(NamedArgument("C", "directory").Description("Project directory")) string directory = ".";
    /// Parallelism; zero uses configuration or logical CPU count.
    @(NamedArgument("jobs", "j").Description("Maximum concurrent actions (0 = automatic)")) size_t jobs;
    /// Promote warnings to diagnostics.
    @NamedArgument("warnings-as-errors") bool warningsAsErrors;
    /// Initialize a new root spec.
    @(NamedArgument("init").Description("Create a Rattspec from a profile")) bool initializeProject;
    /// Include source files and package boilerplate for a shipped profile.
    @(NamedArgument("scaffold").Description("With --init, create a buildable starter project")) bool scaffold;
    /// Profile to preprocess during initialization.
    @NamedArgument("profile") string profile;
    /// List installed profiles.
    @NamedArgument("list-profiles") bool listProfiles;
    /// Write a DOT graph with its canonical payload.
    @NamedArgument("dot") bool dot;
    /// Write canonical graph JSON (the default graph format).
    @NamedArgument("json") bool json;
    /// Import a frozen graph instead of evaluating specs.
    @NamedArgument("import") string importPath;
    /// Graph file or exporter output directory.
    @NamedArgument("output", "o") string output;
    /// Built-in exporter name or plugin library path.
    @NamedArgument("to") string exporter;
    /// Require strict input, output, environment and subprocess isolation.
    @NamedArgument("hermetic") bool hermetic;
    /// Print actions without executing them.
    @NamedArgument("dry-run") bool dryRun;
    /// Print the version and exit.
    @NamedArgument("version") bool version_;
    /// Internal frozen-graph input.
    @(NamedArgument("graph").Hidden) string graph;
    /// Internal action name.
    @(NamedArgument("action").Hidden) string action;
    /// Internal exporter stamp file.
    @(NamedArgument("stamp").Hidden) string stamp;
    /// Internal content-cache switch.
    @(NamedArgument("incremental-action").Hidden) bool incrementalAction;
}

/// Options accepted by the package-manager CLI.
@(Command("rattpkg").Description("Resolve, fetch, and verify pinned package dependencies.")
        .Epilog("Commands: resolve, fetch, verify. Use resolve --update to refresh a lockfile."))
struct PackageOptions
{
    /// Package command.
    @(PositionalArgument.Optional) string[] positional;
    /// Manifest directory.
    @NamedArgument("C", "directory") string directory = ".";
    /// Permit branch references during resolution.
    @NamedArgument("allow-floating") bool allowFloating;
    /// Refresh the existing resolution explicitly.
    @NamedArgument("update") bool update;
    /// Print the version and exit.
    @NamedArgument("version") bool version_;
}

/// Options accepted by the assisted specification editor and directory mapper.
@(Command("rattspec").Description("Create or update Rattpack specifications through an AI"
        ~ " backend, and map directories into a terse inventory.")
        .Epilog("Examples: rattspec assist 'add these libraries: fmt and zlib';"
            ~ " rattspec map . --print"))
struct SpecOptions
{
    /// Subcommand, request text, or the directory to map.
    @(PositionalArgument.Optional) string[] positional;
    /// Project root directory.
    @NamedArgument("C", "directory") string directory = ".";
    /// Assist through OpenCode V2.
    @NamedArgument("opencode") bool useOpenCode;
    /// Assist through an OpenAI-compatible server.
    @NamedArgument("openai") bool useOpenAi;
    /// Assist plugin override; defaults to the backend's plugin beside the CLI.
    @NamedArgument("plugin") string plugin;
    /// OpenCode executable name or path.
    @NamedArgument("opencode-executable") string opencodeExecutable;
    /// Explicit OpenCode server, using the CLI's authentication context.
    @NamedArgument("server") string server;
    /// Run OpenCode with a private server instead of the shared service.
    @(NamedArgument("standalone").Description("Use a private OpenCode server (default on)"))
    bool standalone = true;
    /// OpenAI-compatible base URL.
    @NamedArgument("openai-url") string openaiUrl;
    /// OpenAI API key.
    @NamedArgument("openai-key") string openaiKey;
    /// OpenAI basic-auth user.
    @NamedArgument("openai-user") string openaiUser;
    /// OpenAI basic-auth password.
    @NamedArgument("openai-password") string openaiPassword;
    /// OpenAI endpoint family: chat or responses.
    @NamedArgument("openai-api") string openaiApi;
    /// Model: OpenCode provider/model#variant, or an OpenAI model name.
    @NamedArgument("model") string model;
    /// Request deadline in seconds.
    @NamedArgument("timeout") uint timeout;
    /// Generate and validate a proposal, printing JSON instead of writing files.
    @NamedArgument("dry-run") bool dryRun;
    /// Directory map cache location; defaults to $XDG_CACHE_HOME/rattpack.
    @NamedArgument("map-out") string mapOut;
    /// Include directory totals in rendered map text.
    @(NamedArgument("summary").Description("Include directory file and byte totals (default on)"))
    bool summary = true;
    /// Print rendered map text after writing the binary map.
    @NamedArgument("print") bool printMap;
    /// Print the version and exit.
    @NamedArgument("version") bool version_;
}

/// Options accepted by the standalone interpreter.
@(Command("rattsc").Description("Run Rattscript, lint annotations, or start a REPL.")
        .Epilog(
            "Without a file or -e, starts a REPL; :q exits. Use --test tests/script for golden tests."))
struct ScriptOptions
{
    /// Source filename.
    @(PositionalArgument.Optional) string[] positional;
    /// Statically check the source file.
    @NamedArgument("lint") bool lint;
    /// Golden test directory.
    @NamedArgument("test") string testDirectory;
    /// Source to evaluate directly.
    @NamedArgument("e", "eval") string script;
    /// Print the version and exit.
    @NamedArgument("version") bool version_;
}

/// Parse options and retain argparse's help/error distinction.
auto parseOptions(T)(ref T options, string[] args)
{
    return CLI!T.parseArgs(options, args);
}

/// Validate a public build command before reading a project.
void validateBuildCommand(string command) @safe
{
    if (!["build", "graph", "export", "clean"].canFind(command))
        fail("E_CLI", "unknown command " ~ command);
}
