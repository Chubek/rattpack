module rattpack.stdlib.modules;

import rattpack.script.evaluator;
import rattpack.script.value;
import rattpack.config.environment;
import rattpack.config.templating;
import rattpack.graph.hash;
import rattpack.diagnostic;
import rattpack.rt.sys;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.conv : to;

void installStdlib(Evaluator evaluator, Configuration config = null)
{
    if (config is null)
        config = new Configuration;
    evaluator.sourceTransform = (source, file) => preprocess(source, config,
            [
                "cwd": Value.path(evaluator.cwd),
                "dirname": Value(baseName(evaluator.cwd))
    ], file);
    evaluator.moduleLoader = (string name, Location loc) {
        if (auto value = name in evaluator.modules)
            return *value;
        Value[string] functions;
        void add(string method, Value delegate(Arguments, Location) impl, bool effectful = false)
        {
            functions[method] = evaluator.native(name ~ "." ~ method, impl, effectful);
        }

        string resolve(Value value, Location l)
        {
            return buildNormalizedPath(absolutePath(value.text(l), evaluator.cwd));
        }

        switch (name)
        {
        case "fs":
            add("exists", (a, l) => Value(exists(resolve(a.get("path", 0), l))));
            add("is_file", (a, l) => Value(exists(resolve(a.get("path", 0),
                    l)) && isFile(resolve(a.get("path", 0), l))));
            add("is_dir", (a, l) => Value(exists(resolve(a.get("path", 0),
                    l)) && isDir(resolve(a.get("path", 0), l))));
            add("read", (a, l) {
                auto path = resolve(a.get("path", 0), l);
                auto text = readText(path);
                if (path.endsWith(".in"))
                    text = evaluator.sourceTransform(text, path);
                return Value(text);
            });
            add("hash", (a, l) => Value(hashFile(resolve(a.get("path", 0), l))));
            add("glob", (a, l) {
                auto pattern = a.get("pattern", 0).text(l).replace("\\", "/");
                auto wildcard = pattern.indexOfAny("*?");
                auto prefix = wildcard < 0 ? pattern : pattern[0 .. cast(size_t) wildcard];
                auto slash = prefix.lastIndexOf('/');
                auto searchRoot = slash < 0 ? evaluator.cwd
                    : absolutePath(prefix[0 .. cast(size_t) slash], evaluator.cwd);
                Value[] paths;
                foreach (file; sortedFiles(searchRoot))
                {
                    auto relative = relativePath(file, evaluator.cwd).replace("\\", "/");
                    if (relative.split('/').any!(p => p.startsWith(".")))
                        continue;
                    if (matchGlob(relative, pattern))
                        paths ~= Value.path(relative);
                }
                return Value(paths);
            });
            add("write", (a, l) {
                auto path = resolve(a.get("path", 0), l);
                evaluator.requireWrite(path, l);
                atomicWrite(path, a.get("contents", 1).text(l));
                return Value.init;
            }, true);
            add("mkdir", (a, l) {
                auto path = resolve(a.get("path", 0), l);
                evaluator.requireWrite(path, l);
                mkdirRecurse(path);
                return Value.init;
            }, true);
            add("copy", (a, l) {
                auto dest = resolve(a.get("destination", 1), l);
                evaluator.requireWrite(dest, l);
                mkdirRecurse(dirName(dest));
                copy(resolve(a.get("source", 0), l), dest);
                return Value.init;
            }, true);
            add("remove", (a, l) {
                auto path = resolve(a.get("path", 0), l);
                evaluator.requireWrite(path, l);
                if (exists(path))
                {
                    if (isDir(path))
                        rmdirRecurse(path);
                    else
                        remove(path);
                }
                return Value.init;
            }, true);
            break;
        case "path":
            add("join", (a, l) {
                string[] parts;
                foreach (v; a.positional)
                    parts ~= v.text(l);
                return Value.path(buildPath(parts));
            });
            add("normalize", (a, l) => Value.path(buildNormalizedPath(a.get("path", 0).text(l))));
            add("absolute", (a, l) => Value.path(resolve(a.get("path", 0), l)));
            add("relative", (a, l) => Value.path(relativePath(resolve(a.get("path",
                    0), l), resolve(a.get("base", 1, Value(evaluator.cwd)), l))));
            add("dirname", (a, l) => Value.path(dirName(a.get("path", 0).text(l))));
            add("basename", (a, l) => Value(baseName(a.get("path", 0).text(l))));
            add("extension", (a, l) => Value(extension(a.get("path", 0).text(l))));
            add("stem", (a, l) => Value(stripExtension(baseName(a.get("path", 0).text(l)))));
            add("value", (a, l) => Value.path(a.get("path", 0).text(l)));
            break;
        case "proc":
            add("run", (a, l) {
                string[] argv;
                foreach (v; a.get("command", 0).items(l))
                    argv ~= v.text(l);
                if (!argv.length)
                    fail("E_ARITY", "proc.run needs a command", l);
                auto cwd = a.get("cwd", 1, Value(evaluator.cwd)).text(l);
                auto processDirectory = absolutePath(cwd, evaluator.cwd);
                auto result = evaluator.processRunner is null ? runProcess(argv,
                    processDirectory) : evaluator.processRunner(argv, processDirectory);
                if (result.output.length && evaluator.output !is null)
                    evaluator.output(result.output.stripRight);
                if (result.status && a.get("check", 2, Value(true)).truth)
                    fail("E_ACTION",
                        "command exited with status " ~ result.status.to!string ~ ": " ~ argv[0], l);
                return Value([
                    "code": Value(result.status),
                    "output": Value(result.output)
                ]);
            }, true);
            add("which", (a, l) => Value.path(locateProgram(a.get("name", 0).text(l))));
            add("env", (a, l) {
                import std.process : environment;

                return Value(environment.get(a.get("name", 0).text(l),
                    a.get("default", 1, Value("")).text(l)));
            }, true);
            break;
        case "str":
            add("split", (a, l) {
                Value[] values;
                foreach (s; a.get("value", 0).text(l).split(a.get("separator",
                    1, Value(" ")).text(l)))
                    values ~= Value(s);
                return Value(values);
            });
            add("join", (a, l) {
                string[] values;
                foreach (v; a.get("values", 0).items(l))
                    values ~= v.str;
                return Value(values.join(a.get("separator", 1, Value("")).text(l)));
            });
            add("replace", (a, l) => Value(a.get("value", 0).text(l)
                    .replace(a.get("old", 1).text(l), a.get("new", 2).text(l))));
            add("lower", (a, l) => Value(a.get("value", 0).text(l).toLower));
            add("upper", (a, l) => Value(a.get("value", 0).text(l).toUpper));
            add("trim", (a, l) => Value(a.get("value", 0).text(l).strip));
            add("contains", (a, l) => Value(a.get("value", 0).text(l)
                    .canFind(a.get("needle", 1).text(l))));
            add("starts_with", (a, l) => Value(a.get("value", 0).text(l)
                    .startsWith(a.get("prefix", 1).text(l))));
            add("ends_with", (a, l) => Value(a.get("value", 0).text(l)
                    .endsWith(a.get("suffix", 1).text(l))));
            add("format", (a, l) {
                auto value = a.get("template", 0).text(l);
                auto fields = a.get("values", 1);
                if (fields.kind != Value.Kind.map)
                    fail("E_TYPE", "str.format needs a map", l);
                foreach (key; fields.data.mapValue.values.keys.sort)
                    value = value.replace("{" ~ key ~ "}", fields.data.mapValue.values[key].str);
                return Value(value);
            });
            break;
        case "env":
            add("get", (a, l) => config.get(a.get("key", 0).text(l), a.get("default", 1)));
            add("has", (a, l) => Value((a.get("key", 0).text(l) in config.values) !is null));
            break;
        case "toolchain":
            functions["shared_suffix"] = Value(sharedSuffix);
            functions["executable_suffix"] = Value(executableSuffix);
            functions["platform"] = Value(backendName);
            functions["runtime_library"] = Value((backendName == "win32"
                    ? "rattpack" : "librattpack") ~ sharedSuffix);
            add("discover", (a, l) {
                auto language = a.get("language", 0).text(l);
                auto command = config.text("toolchain." ~ language,
                    language == "d" ? "ldc2" : language == "cxx" ? "c++" : "cc");
                auto path = locateProgram(command);
                if (!path.length)
                    fail("E_TARGET", "compiler not found: " ~ command, l);
                auto result = runProcess([path, "--version"], evaluator.cwd);
                return Value([
                    "command": Value(path),
                    "version": Value(result.output.strip),
                    "fingerprint": Value(hashParts([
                        path, hashFile(path), result.output
                    ]))
                ]);
            });
            add("flags", (a, l) {
                auto mode = a.get("mode", 0, Value("debug")).text(l);
                Value[] flags = mode == "release" ? [Value("-O2")] : [
                    Value("-g")
                ];
                return Value(flags);
            });
            break;
        case "log":
            void addLog(string level)
            {
                add(level, (a, l) {
                    if (evaluator.output !is null)
                        evaluator.output(level ~ ": " ~ a.get("message", 0).str);
                    return Value.init;
                });
            }

            foreach (method; ["info", "warn", "error", "debug"])
                addLog(method);
            break;
        case "target":
        case "pkg":
            fail("E_IMPORT", name ~ " is available in a project context", loc);
            break;
        case "collections":
            auto scope_ = new Environment(evaluator.globals);
            evaluator.run(import("collections.ratt"), "<stdlib:collections>", scope_);
            return Value(scope_.values);
        default:
            fail("E_IMPORT", "unknown standard module '" ~ name ~ "'", loc);
        }
        return Value(functions);
    };
}

bool matchGlob(string path, string pattern) @safe
{
    import std.regex : regex, matchFirst;

    string expression = "^";
    for (size_t i; i < pattern.length; i++)
    {
        auto c = pattern[i];
        if (c == '*' && i + 1 < pattern.length && pattern[i + 1] == '*')
        {
            i++;
            if (i + 1 < pattern.length && pattern[i + 1] == '/')
            {
                i++;
                expression ~= "(?:.*/)?";
            }
            else
                expression ~= ".*";
        }
        else if (c == '*')
            expression ~= "[^/]*";
        else if (c == '?')
            expression ~= "[^/]";
        else
        {
            if (".()[]{}+^$|\\".canFind(c))
                expression ~= '\\';
            expression ~= c;
        }
    }
    return !matchFirst(path, regex(expression ~ "$", "")).empty;
}
