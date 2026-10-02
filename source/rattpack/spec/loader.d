module rattpack.spec.loader;

import rattpack.script.evaluator;
import rattpack.script.value;
import rattpack.script.snapshot;
import rattpack.config.environment;
import rattpack.config.templating;
import rattpack.stdlib.modules;
import rattpack.graph.model;
import rattpack.graph.hash;
import rattpack.diagnostic;
import rattpack.rt.sys;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array : array;
import std.conv : to;

private class Context
{
    string directory;
    string namespace;
    string identity;
    string packageRoot;
    string kind;
    string file;
    bool subordinate;
    bool sharedIdentity;
    bool declared;
    bool serial;
    string[string] members;
    string[] ignored;
    size_t targetCount;
}

private class Definition
{
    string name;
    string kind;
    string output;
    Value[string] fields;
    Context context;
    DeferredAction[] deferred;
}

class SpecLoader
{
    Graph graph;
    Configuration configuration;
    bool warningsAsErrors;
    WarningSink warnings;
    Definition[] definitions;
    string[string] toolchains;

    this(string root, Configuration configuration, bool warningsAsErrors = false,
            WarningSink warnings = null)
    {
        graph = new Graph(root);
        this.configuration = configuration;
        this.warningsAsErrors = warningsAsErrors;
        this.warnings = warnings;
    }

    Graph load()
    {
        auto context = new Context;
        context.directory = graph.root;
        context.file = buildPath(graph.root, "Rattspec");
        context.packageRoot = graph.root;
        if (!exists(context.file) && exists(context.file ~ ".in"))
            context.file ~= ".in";
        if (!exists(context.file))
            fail("E_SPEC", "Rattspec not found in " ~ graph.root);
        evaluate(context);
        graph.projectName = context.identity;
        discover(context.directory, context);
        lower;
        graph.finalize;
        return graph;
    }

    private void evaluate(Context context)
    {
        auto evaluator = new Evaluator(Phase.construction, context.directory);
        installStdlib(evaluator, configuration);
        auto scope_ = new Environment(evaluator.globals);
        Definition last;
        evaluator.bind("project", (Arguments a, Location l) {
            if (context.subordinate || context.declared)
                fail("E_IDENTITY_MISMATCH",
                    "project() requires a root Rattspec and one identity declaration", l);
            auto name = a.get("name", 0).text(l);
            auto kind = a.get("kind", 2, Value("single")).text(l);
            a.get("version", 1).text(l);
            if (!["single", "multi-module", "monorepo"].canFind(kind))
                fail("E_SPEC", "invalid project kind", l);
            if (!context.sharedIdentity)
            {
                context.identity = name;
                context.kind = kind;
            }
            if (context.namespace == "@project")
                context.namespace = name;
            context.declared = true;
            return Value([
                "name": Value(context.identity),
                "kind": Value(context.kind)
            ]);
        });
        evaluator.bind("module", (Arguments a, Location l) {
            if (!context.subordinate || context.declared)
                fail("E_IDENTITY_MISMATCH", "module() requires Rattspec.m", l);
            auto name = a.get("name", 0).text(l);
            context.namespace ~= (context.namespace.length ? "::" : "") ~ name;
            context.declared = true;
            return Value(name);
        });
        Value declare(string kind, Arguments a, Location l)
        {
            if (!context.declared)
                fail("E_SPEC", "declare the project or module before targets", l);
            auto name = a.get("name", 0).text(l);
            if (!name.length || name.canFind('/') || name.canFind('\\'))
                fail("E_TARGET", "target names cannot contain path separators", l);
            auto definition = new Definition;
            definition.name = context.namespace.length ? context.namespace ~ "::" ~ name : name;
            definition.kind = kind;
            definition.fields = a.named.dup;
            definition.context = context;
            auto language = a.get("language", 2, Value("c")).text(l);
            auto output = a.get("output", 3, Value("")).text(l);
            if (!output.length)
            {
                auto suffix = kind == "library" ? (a.get("shared", 4,
                        Value(false)).truth ? sharedSuffix : staticSuffix) : executableSuffix;
                output = buildPath("build", (kind == "library" ? "lib" : "") ~ name ~ suffix);
            }
            definition.output = relativePath(absolutePath(output, context.directory), graph.root);
            definition.fields["name"] = Value(definition.name);
            definition.fields["output"] = Value.path(definition.output);
            definition.fields["language"] = Value(language);
            if (!("sources" in definition.fields))
                definition.fields["sources"] = a.get("sources", 1, Value(cast(Value[])[
            ]));
            foreach (other; definitions)
                if (other.name == definition.name)
                    fail("E_TARGET", "duplicate target '" ~ definition.name ~ "'", l);
            definitions ~= definition;
            last = definition;
            context.targetCount++;
            return Value.handle(kind == "rule" ? Value.Kind.rule
                    : Value.Kind.target, definition.name, definition.fields);
        }

        evaluator.bind("target", (a, l) {
            return declare(a.get("kind", 4, Value("executable")).text(l), a, l);
        });
        evaluator.bind("rule", (a, l) { return declare("rule", a, l); });
        Value[string] targetModule;
        targetModule["executable"] = evaluator.native("target.executable", (a,
                l) => declare("executable", a, l));
        targetModule["library"] = evaluator.native("target.library", (a,
                l) => declare("library", a, l));
        targetModule["rule"] = evaluator.native("target.rule", (a, l) => declare("rule", a, l));
        evaluator.modules["target"] = Value(targetModule);
        void bindDirective(string mode)
        {
            evaluator.bind(mode, (a, l) {
                if (context.kind != "monorepo")
                    fail("E_SPEC", "monorepo declarations require kind: monorepo", l);
                auto path = buildNormalizedPath(absolutePath(a.get("path", 0)
                    .text(l), context.directory));
                if (!path.startsWith(context.directory ~ dirSeparator))
                    fail("E_SPEC", "member must be inside its project", l);
                if (mode == "ignore")
                    context.ignored ~= path;
                else
                {
                    if (path in context.members)
                        fail("E_SPEC", "duplicate monorepo member", l);
                    context.members[path] = mode;
                }
                return Value.init;
            });
        }

        foreach (directive; ["member", "vendored", "ignore"])
            bindDirective(directive);
        // Build evaluation has read-only access to dependencies already fetched
        // by rattpkg. No network operation is reachable from these functions.
        Value[string] pkgModule;
        pkgModule["get"] = evaluator.native("pkg.get", (a, l) {
            import rattpack.pkg.lockfile : readLock;

            auto name = a.get("name", 0).text(l);
            auto lock = readLock(buildPath(context.packageRoot, "Rattpkg.lock"));
            foreach (entry; lock.entries)
                if (entry.name == name)
                {
                    auto path = buildPath(cacheHome, "rattpack", "pkgs",
                        entry.name, entry.treeHash);
                    if (!exists(path))
                        fail("E_PACKAGE", "dependency is not fetched: " ~ name, l);
                    return Value.handle(Value.Kind.pkg, name,
                        [
                            "path": Value.path(path),
                            "version": Value(entry.version_)
                    ]);
                }
            fail("E_PACKAGE", "dependency not found in lockfile: " ~ name, l);
            return Value.init;
        });
        evaluator.modules["pkg"] = Value(pkgModule);
        evaluator.actionHandler = (DeferredAction action) {
            auto definition = last;
            if (action.target.kind != Value.Kind.nil)
            {
                definition = null;
                foreach (entry; definitions)
                    if (entry.name == action.target.str)
                        definition = entry;
            }
            if (definition is null)
                fail("E_TARGET", "action must reference a declared target", action.location);
            definition.deferred ~= action;
        };
        auto source = readText(context.file);
        evaluator.run(source, context.file, scope_);
        if (!context.declared)
            fail("E_IDENTITY_MISMATCH", context.subordinate
                    ? "Rattspec.m must call module()" : "Rattspec must call project()",
                    Location(context.file));
        if (!context.subordinate && !context.targetCount)
            fail("E_SPEC", "Rattspec must declare at least one target", Location(context.file));
        foreach (path; context.members.keys.sort)
            if (!exists(buildPath(path, "Rattspec")) && !exists(buildPath(path, "Rattspec.in")))
                fail("E_SPEC", "member has no Rattspec: " ~ path, Location(context.file));
    }

    private void discover(string directory, Context parent)
    {
        string[] directories;
        foreach (entry; dirEntries(directory, SpanMode.shallow))
            if (entry.isDir && !entry.isSymlink && !baseName(entry.name)
                    .startsWith(".") && baseName(entry.name) != "build")
                directories ~= entry.name;
        foreach (path; directories.sort)
        {
            bool ignored;
            foreach (ignore; parent.ignored)
                if (path == ignore || path.startsWith(ignore ~ dirSeparator))
                    ignored = true;
            if (ignored)
                continue;
            auto rootSpec = buildPath(path, "Rattspec"), moduleSpec = buildPath(path, "Rattspec.m");
            if (!exists(rootSpec) && exists(rootSpec ~ ".in"))
                rootSpec ~= ".in";
            if (!exists(moduleSpec) && exists(moduleSpec ~ ".in"))
                moduleSpec ~= ".in";
            if (exists(rootSpec) && exists(moduleSpec))
                fail("E_IDENTITY_MISMATCH",
                        "directory contains both Rattspec and Rattspec.m", Location(rootSpec));
            if (exists(rootSpec) || exists(moduleSpec))
            {
                auto context = new Context;
                context.directory = path;
                context.subordinate = exists(moduleSpec);
                context.file = context.subordinate ? moduleSpec : rootSpec;
                context.identity = parent.identity;
                context.kind = parent.kind;
                context.namespace = parent.namespace;
                context.serial = parent.serial;
                context.packageRoot = parent.packageRoot;
                if (!context.subordinate)
                {
                    if (path in parent.members)
                    {
                        context.namespace = "";
                        context.packageRoot = path;
                    }
                    else
                    {
                        warning("W_UNDECLARED_NESTED_SPEC",
                                "nested project must be declared as a monorepo member: " ~ rootSpec,
                                Location(rootSpec), warningsAsErrors, warnings);
                        context.sharedIdentity = true;
                        context.serial = true;
                        foreach (definition; definitions)
                            definition.context.serial = true;
                    }
                }
                if (!context.subordinate && !context.sharedIdentity)
                {
                    // Set the namespace before the first declaration so every
                    // member preserves its project identity and resource scope.
                    context.namespace = "@project";
                }
                evaluate(context);
                discover(path, context);
            }
            else
                discover(path, parent);
        }
    }

    private string compilerFingerprint(string compiler)
    {
        if (auto value = compiler in toolchains)
            return *value;
        auto result = runProcess([compiler, "--version"], graph.root);
        auto value = hashParts([compiler, hashFile(compiler), result.output]);
        toolchains[compiler] = value;
        return value;
    }

    private void lower()
    {
        foreach (definition; definitions)
        {
            auto action = new Action;
            action.name = definition.name;
            action.outputs = [definition.output];
            action.cwd = definition.context.directory;
            action.serial = definition.context.serial;
            auto fields = definition.fields;
            auto settings = new Environment;
            settings.values = configuration.values;
            action.settings = freeze(DeferredAction(Value.init, null, settings));
            action.sandbox = fields.get("sandbox", Value(true)).truth;
            action.toolchain = fields.get("toolchain", Value("")).str;
            foreach (key; ["sources", "inputs", "headers", "raw_inputs"])
                if (auto values = key in fields)
                    foreach (value; values.items)
                        action.inputs ~= key == "raw_inputs" ? relativePath(absolutePath(value.text,
                                action.cwd), graph.root) : configureInput(value.text, action.cwd);
            if (auto dependencies = "deps" in fields)
                foreach (dependency; dependencies.items)
                {
                    auto name = dependency.str;
                    if (!name.canFind("::") && definition.context.namespace.length)
                        name = definition.context.namespace ~ "::" ~ name;
                    action.dependencies ~= name;
                    bool found;
                    foreach (entry; definitions)
                        if (entry.name == name)
                        {
                            action.inputs ~= entry.output;
                            found = true;
                        }
                    if (!found)
                        fail("E_TARGET", "unknown dependency " ~ name);
                }
            auto command = fields.get("command", Value.init);
            if (command.kind != Value.Kind.nil)
            {
                string[] argv;
                foreach (value; command.items)
                    argv ~= value.text;
                action.commands ~= argv;
                if (argv.length)
                {
                    auto program = locateProgram(argv[0]);
                    if (program.length)
                        action.toolchain = hashParts([
                        action.toolchain, compilerFingerprint(program)
                    ]);
                }
            }
            else if (definition.kind != "rule" && !definition.deferred.length)
                compileTarget(definition, action);
            foreach (deferred; definition.deferred)
            {
                if (action.snapshot.length)
                    fail("E_TARGET", "a target may have only one action block");
                action.snapshot = freeze(deferred);
            }
            if (action.snapshot.length)
            {
                string[] fingerprints = [action.toolchain];
                foreach (language; ["c", "cxx", "d"])
                {
                    auto program = locateProgram(configuration.text("toolchain." ~ language));
                    if (program.length)
                        fingerprints ~= compilerFingerprint(program);
                }
                action.toolchain = hashParts(fingerprints);
            }
            if (!action.commands.length && !action.snapshot.length)
                fail("E_TARGET", "target has no action: " ~ action.name);
            graph.add(action);
        }
    }

    private void compileTarget(Definition definition, Action action)
    {
        auto fields = definition.fields;
        auto language = fields["language"].text;
        if (!["c", "cxx", "d"].canFind(language))
            fail("E_TARGET", "unsupported language " ~ language);
        auto compiler = locateProgram(fields.get("compiler",
                Value(configuration.text("toolchain." ~ language))).text);
        if (!compiler.length)
            fail("E_TARGET", "compiler not found for " ~ language);
        action.toolchain = compilerFingerprint(compiler);
        string[] sources;
        foreach (v; fields["sources"].items)
            sources ~= absolutePath(v.text.endsWith(".in") ? v.text[0 .. $ - 3] : v.text,
                    action.cwd);
        if (!sources.length)
            fail("E_TARGET", "compiled target has no sources: " ~ action.name);
        string[] flags;
        if (auto values = "flags" in fields)
            foreach (v; values.items)
                flags ~= v.text;
        if (auto values = "include_dirs" in fields)
            foreach (v; values.items)
                flags ~= "-I" ~ absolutePath(v.text, action.cwd);
        string[] libraries;
        if (auto values = "deps" in fields)
            foreach (v; values.items)
                foreach (entry; definitions)
                    if (entry.name == v.str
                            || entry.name == definition.context.namespace ~ "::" ~ v.str)
                        if (entry.kind == "library")
                            libraries ~= absolutePath(entry.output, graph.root);
        if (auto values = "link_flags" in fields)
            foreach (v; values.items)
                libraries ~= v.text;
        auto output = absolutePath(definition.output, graph.root);
        auto isShared = fields.get("shared", Value(false)).truth;
        if (language == "d")
        {
            string[] argv = [compiler] ~ flags ~ sources;
            if (definition.kind == "library")
                argv ~= isShared ? ["-shared", "-fPIC"] : ["-lib"];
            argv ~= libraries ~ ["-of=" ~ output];
            action.commands ~= argv;
        }
        else if (definition.kind == "library" && !isShared)
        {
            string[] objects;
            foreach (i, source; sources)
            {
                auto objectPath = buildPath(dirName(output),
                        stripExtension(baseName(output)) ~ "-" ~ i.to!string ~ ".o");
                action.commands ~= [compiler] ~ flags ~ [
                    "-c", source, "-o", objectPath
                ];
                objects ~= objectPath;
            }
            auto archiver = locateProgram("ar");
            if (!archiver.length)
                fail("E_TARGET", "archiver not found");
            action.commands ~= [archiver, "rcs", output] ~ objects;
            action.toolchain = hashParts([
                action.toolchain, compilerFingerprint(archiver)
            ]);
        }
        else
        {
            string[] argv = [compiler] ~ flags;
            if (isShared)
                argv ~= ["-shared", "-fPIC"];
            action.commands ~= argv ~ sources ~ libraries ~ ["-o", output];
        }
    }

    private string configureInput(string path, string cwd)
    {
        auto relative = relativePath(absolutePath(path, cwd), graph.root);
        if (!path.endsWith(".in"))
            return relative;
        auto configured = relative[0 .. $ - 3];
        auto name = "@template:" ~ hashBytes(relative)[0 .. 16];
        if (!(name in graph.actions))
        {
            auto input = absolutePath(path, cwd);
            if (!exists(input))
                fail("E_TEMPLATE", "template input not found: " ~ path);
            auto contents = preprocess(readText(input), configuration,
                    ["cwd": Value.path(cwd), "dirname": Value(baseName(cwd))], input);
            import std.json : JSONValue;

            auto evaluator = new Evaluator(Phase.construction, cwd);
            installStdlib(evaluator, configuration);
            DeferredAction deferred;
            evaluator.actionHandler = (value) { deferred = value; };
            evaluator.run("import \"fs\"\naction { fs.write(" ~ JSONValue(absolutePath(configured,
                    graph.root)).toString ~ ", " ~ JSONValue(contents)
                    .toString ~ ") }", input ~ ":configure");
            auto action = new Action;
            action.name = name;
            action.inputs = [relative];
            action.outputs = [configured];
            auto settings = new Environment;
            settings.values = configuration.values;
            action.settings = freeze(DeferredAction(Value.init, null, settings));
            action.snapshot = freeze(deferred);
            action.cwd = cwd;
            action.toolchain = hashBytes("rattpack-template-v1");
            graph.add(action);
        }
        return configured;
    }
}
