module rattpack.config.templating;

import rattpack.script.evaluator;
import rattpack.script.parser;
import rattpack.script.value;
import rattpack.stdlib.modules;
import rattpack.config.environment;
import rattpack.diagnostic;
import std.string;
import std.json : JSONValue;

string preprocess(string input, Configuration config, Value[string] extra = null,
        string file = "<template>")
{
    auto evaluator = new Evaluator(Phase.construction, extra.get("cwd", Value.path(".")).text);
    installStdlib(evaluator, config);
    evaluator.globals.values["env"] = evaluator.importModule("env", Location(file));
    // Nested config maps support @{user.name} as well as env.get(...).
    foreach (key, value; config.values)
    {
        auto parts = key.split('.');
        auto scopeValues = &evaluator.globals.values;
        foreach (part; parts[0 .. $ - 1])
        {
            if (!(part in *scopeValues) || (*scopeValues)[part].kind != Value.Kind.map)
                (*scopeValues)[part] = Value(cast(Value[string]) null);
            scopeValues = &(*scopeValues)[part].data.mapValue.values;
        }
        (*scopeValues)[parts[$ - 1]] = value;
    }
    foreach (key, value; extra)
        evaluator.globals.values[key] = value;
    string result;
    evaluator.bind("__emit", (Arguments a, Location l) {
        result ~= a.get("value", 0).str;
        return Value.init;
    });
    string program;
    size_t depth;
    foreach (line; input.splitLines(KeepTerminator.yes))
    {
        auto trimmed = line.strip;
        if (trimmed.startsWith("@if "))
        {
            program ~= "if " ~ trimmed[4 .. $] ~ " {\n";
            depth++;
            continue;
        }
        if (trimmed == "@else")
        {
            if (!depth)
                fail("E_TEMPLATE", "unmatched @else", Location(file));
            program ~= "} else {\n";
            continue;
        }
        if (trimmed == "@end")
        {
            if (!depth)
                fail("E_TEMPLATE", "unmatched @end", Location(file));
            program ~= "}\n";
            depth--;
            continue;
        }
        if (trimmed.startsWith("@foreach "))
        {
            program ~= "for " ~ trimmed[9 .. $] ~ " {\n";
            depth++;
            continue;
        }
        size_t start;
        while (start < line.length)
        {
            auto position = line[start .. $].indexOf("@{");
            if (position < 0)
            {
                program ~= "__emit(" ~ JSONValue(line[start .. $]).toString ~ ")\n";
                break;
            }
            auto opening = start + cast(size_t) position;
            if (opening > start)
                program ~= "__emit(" ~ JSONValue(line[start .. opening]).toString ~ ")\n";
            auto end = opening + 2;
            size_t braces = 1;
            char quote = 0;
            bool escape;
            for (; end < line.length; end++)
            {
                auto c = line[end];
                if (quote)
                {
                    if (escape)
                        escape = false;
                    else if (c == '\\')
                        escape = true;
                    else if (c == quote)
                        quote = 0;
                }
                else if (c == '"' || c == '\'')
                    quote = c;
                else if (c == '{')
                    braces++;
                else if (c == '}' && --braces == 0)
                    break;
            }
            if (end == line.length)
                fail("E_TEMPLATE", "unclosed substitution", Location(file));
            program ~= "__emit(" ~ line[opening + 2 .. end] ~ ")\n";
            start = end + 1;
        }
    }
    if (depth)
        fail("E_TEMPLATE", "unclosed template directive", Location(file));
    try
    {
        evaluator.run(program, file, null, false);
    }
    catch (Diagnostic d)
    {
        if (d.code == "E_PHASE_VIOLATION")
            throw d;
        fail("E_TEMPLATE", d.msg, Location(file));
    }
    return result;
}
