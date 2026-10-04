module rattpack.lsp.catalog;

import rattpack.script.ast;
import rattpack.script.parser : Parser;
import std.algorithm : canFind;
import std.json : JSONValue;
import std.string : indexOf, startsWith;

struct Suggestion
{
    string name;
    string detail;
    string documentation;
    int kind = 3; // LSP CompletionItemKind.Function
}

enum string[] moduleNames = [
    "fs", "path", "proc", "str", "toolchain", "target", "pkg", "env", "log",
    "collections", "list", "dict", "sets", "iter", "functional", "math",
    "stats", "json", "regex", "base64", "semver"
];

enum string[] keywords = [
    "let", "var", "const", "fn", "import", "as", "if", "else", "while", "for",
    "foreach", "in", "return", "break", "continue", "action", "and", "or",
    "not", "true", "false", "nil"
];

enum string[] annotations = [
    "any", "nil", "bool", "int", "float", "str", "path", "list", "map", "set",
    "fn", "target", "rule", "pkg"
];

private string describe(Expr expression) @safe
{
    if (expression is null)
        return "nil";
    if (expression.kind == ExprKind.literal)
    {
        if (expression.literal.typeName == "str")
            return JSONValue(expression.literal.str).toString;
        return expression.literal.str;
    }
    if (expression.kind == ExprKind.name)
        return expression.text;
    if (expression.kind == ExprKind.list)
        return "[]";
    if (expression.kind == ExprKind.map)
        return "{}";
    if (expression.kind == ExprKind.unary)
        return expression.text ~ describe(expression.left);
    return "…";
}

string signature(string name, Parameter[] parameters, string result = "") @safe
{
    string text = "fn " ~ name ~ "(";
    foreach (index, parameter; parameters)
    {
        if (index)
            text ~= ", ";
        text ~= parameter.name;
        if (parameter.annotation.length)
            text ~= ": " ~ parameter.annotation;
        if (parameter.defaultValue !is null)
            text ~= " = " ~ describe(parameter.defaultValue);
    }
    return text ~ ")" ~ (result.length ? " -> " ~ result : "");
}

/// Static metadata only: constructing the catalog never evaluates Rattscript.
final class Catalog
{
    Suggestion[] builtins;
    Suggestion[][string] modules;

    this() @safe
    {
        void add(string module_, string declaration, string documentation = "")
        {
            auto paren = declaration.indexOf('(');
            auto name = paren < 0 ? declaration : declaration[0 .. cast(size_t) paren];
            auto item = Suggestion(name, module_.length ? module_ ~ "." ~ declaration
                    : declaration, documentation, paren < 0 ? 21 : 3);
            if (module_.length)
                modules[module_] ~= item;
            else
                builtins ~= item;
        }

        add("", "print(value, ...)", "Print values separated by spaces.");
        add("", `assert(condition, message = "assertion failed")`,
                "Raise E_RUNTIME if the condition is false-like.");
        add("", "len(value) -> int", "Count collection entries or string/path bytes.");
        add("", "type(value) -> str", "Return the runtime value kind.");
        add("", "str(value) -> str", "Convert a value to display text.");
        add("", "int(value) -> int", "Convert a number or parse integer text.");
        add("", "float(value) -> float", "Convert a number or parse floating-point text.");
        add("", "set(values = []) -> set", "Construct a structurally unique collection.");
        add("", "range(start, end, step = 1) -> list",
                "Create an eager range; a single argument is the end.");
        add("", "sorted(values) -> list",
                "Sort by display text; use list.sort for numeric ordering.");
        add("", "keys(map) -> list", "Return sorted string keys.");
        foreach (declaration; [
            "project(name, version, kind)", "module(name)",
            "target(name, sources = [], language = \"c\")",
            "rule(name, output, inputs = [])", "package(name, version, license)",
            "git(url)", "http(url)", "ftp(url)"
        ])
            add("", declaration,
                    "Host declaration; available in the corresponding build/package context.");

        foreach (declaration; [
            "exists(path)", "is_file(path)", "is_dir(path)", "read(path)",
            "hash(path)", "glob(pattern)"
        ])
            add("fs", declaration,
                    "Deterministic filesystem query; declare execution-time reads as action inputs.");
        foreach (declaration; [
            "write(path, contents)", "mkdir(path)", "copy(source, destination)",
            "remove(path)"
        ])
            add("fs", declaration, "Effectful: requires an action or standalone execution.");
        foreach (declaration; [
            "join(...)", "normalize(path)", "absolute(path)",
            "relative(path, base)", "dirname(path)", "basename(path)",
            "extension(path)", "stem(path)", "value(path)"
        ])
            add("path", declaration, "Portable path manipulation.");
        add("proc", "run(command, cwd, check = true)",
                "Effectful: run an argv list, returning code and output.");
        add("proc", "which(name)", "Discover a program without spawning it.");
        add("proc", "env(name, default = \"\")",
                "Effectful: read the captured action or standalone process environment.");
        foreach (declaration; [
            "split(value, separator = \" \")", "join(values, separator = \"\")",
            "replace(value, old, new)", "lower(value)", "upper(value)",
            "trim(value)", "contains(value, needle)", "starts_with(value, prefix)",
            "ends_with(value, suffix)", "format(template, values)"
        ])
            add("str", declaration, "String transformation.");
        add("env", "get(key, default = nil)", "Read captured configuration by dotted key.");
        add("env", "has(key)", "Test whether a configuration key exists.");
        add("toolchain", "discover(language)",
                "Discover and fingerprint the configured compiler.");
        add("toolchain", "flags(mode = \"debug\")", "Return flags for the selected build mode.");
        foreach (name; [
            "platform", "executable_suffix", "shared_suffix", "runtime_library"
        ])
            add("toolchain", name, "Platform-dependent build metadata.");
        foreach (name; ["executable", "library", "rule"])
            add("target", name ~ "(name, sources = [], language = \"c\", output)",
                    "Declare a build target in a spec.");
        add("pkg", "get(name)", "Read a resolved, fetched dependency; never downloads packages.");
        foreach (name; ["info", "warn", "error", "debug"])
            add("log", name ~ "(message)", "Emit a structured log message.");

        static foreach (name; [
            "collections", "list", "dict", "sets", "iter", "functional",
            "math", "stats", "json", "regex", "base64", "semver"
        ])
        {
            {
                auto source = import(name ~ ".ratt");
                auto ast = new Parser(source, "<stdlib:" ~ name ~ ">").parse;
                foreach (statement; ast.statements)
                {
                    if (statement.name.startsWith("_"))
                        continue;
                    if (statement.kind == StmtKind.function_)
                        modules[name] ~= Suggestion(statement.name,
                                signature(name ~ "." ~ statement.name, statement.parameters,
                                    statement.annotation),
                                "Embedded Rattscript standard-library function.");
                    else if (statement.kind == StmtKind.variable)
                        modules[name] ~= Suggestion(statement.name, "let " ~ name ~ "." ~ statement.name,
                                "Embedded standard-library constant.", 21);
                }
            }
        }
    }

    bool hasModule(string name) const @safe
    {
        return moduleNames.canFind(name);
    }
}
