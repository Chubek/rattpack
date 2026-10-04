/// Native primitives used by the embedded Rattscript standard modules.
module rattpack.stdlib.primitives;

import rattpack.diagnostic : Location, fail;
import rattpack.script.evaluator : Evaluator;
import rattpack.script.value : Arguments, Value;
import std.algorithm : canFind, sort;
import std.base64 : Base64, Base64URL;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.math;
import std.regex : regex, matchFirst, matchAll, replaceAll, split, escaper;
import std.array : array;
import std.conv : to;
import std.string : join;
import std.utf : validate;

/// Register primitives eagerly so native references can be thawed in actions
/// even when the execution evaluator has not imported the source module yet.
Value[string][string] installPrimitives(Evaluator evaluator) @safe
{
    Value[string][string] modules;
    void add(string module_, string name, Value delegate(Arguments, Location) impl) @safe
    {
        modules[module_][name] = evaluator.native(module_ ~ "." ~ name, impl);
    }

    modules["math"]["pi"] = Value(cast(double) PI);
    modules["math"]["e"] = Value(cast(double) E);
    void unary(string name, double delegate(double) operation) @safe
    {
        add("math", name, (a, l) {
            auto value = a.get("value", 0).number(l);
            if (!isFinite(value))
                fail("E_RUNTIME", "math." ~ name ~ " needs a finite number", l);
            auto result = operation(value);
            if (!isFinite(result))
                fail("E_RUNTIME", "math." ~ name ~ " result is not finite", l);
            return Value(result);
        });
    }

    unary("sqrt", (x) => sqrt(x));
    unary("floor", (x) => floor(x));
    unary("ceil", (x) => ceil(x));
    unary("round", (x) => round(x));
    unary("log", (x) => log(x));
    unary("exp", (x) => exp(x));
    unary("sin", (x) => sin(x));
    unary("cos", (x) => cos(x));
    unary("tan", (x) => tan(x));
    add("math", "is_finite", (a, l) => Value(isFinite(a.get("value", 0).number(l))));

    add("json", "parse", (a, l) {
        auto text = a.get("value", 0).text(l);
        validate(text);
        return fromJSON(parseJSON(text, 256, JSONOptions.strictParsing), l);
    });
    add("json", "stringify", (a, l) => Value(formatJSON(toJSON(a.get("value",
            0), l), a.get("pretty", 1, Value(false)).truth)));

    add("regex", "test", (a, l) => Value(!matchFirst(a.get("value", 0)
            .text(l), regex(a.get("pattern", 1).text(l), a.get("flags", 2, Value("")).text(l)))
            .empty));
    add("regex", "find", (a, l) {
        auto match = matchFirst(a.get("value", 0).text(l),
            regex(a.get("pattern", 1).text(l), a.get("flags", 2, Value("")).text(l)));
        if (match.empty)
            return Value.init;
        Value[] captures;
        foreach (capture; match)
            captures ~= Value(capture);
        return Value(captures);
    });
    add("regex", "find_all", (a, l) {
        Value[] matches;
        foreach (match; matchAll(a.get("value", 0).text(l),
            regex(a.get("pattern", 1).text(l), a.get("flags", 2, Value("")).text(l))))
        {
            Value[] captures;
            foreach (capture; match)
                captures ~= Value(capture);
            matches ~= Value(captures);
        }
        return Value(matches);
    });
    add("regex", "replace", (a, l) => Value(replaceAll(a.get("value", 0)
            .text(l), regex(a.get("pattern", 1).text(l), a.get("flags", 3, Value("")).text(l)),
            a.get("replacement", 2).text(l))));
    add("regex", "split", (a, l) {
        Value[] pieces;
        foreach (piece; split(a.get("value", 0).text(l), regex(a.get("pattern",
            1).text(l), a.get("flags", 2, Value("")).text(l))))
            pieces ~= Value(piece);
        return Value(pieces);
    });
    add("regex", "escape", (a, l) => Value(a.get("value", 0).text(l).escaper.array.to!string));

    add("base64", "encode", (a, l) {
        auto bytes = cast(const(ubyte)[]) a.get("value", 0).text(l);
        return Value(a.get("url_safe", 1, Value(false)).truth
            ? Base64URL.encode(bytes) : Base64.encode(bytes));
    });
    add("base64", "decode", (a, l) {
        auto text = a.get("value", 0).text(l);
        auto urlSafe = a.get("url_safe", 1, Value(false)).truth;
        auto bytes = urlSafe ? Base64URL.decode(text) : Base64.decode(text);
        // Reject missing/excess padding, non-alphabet bytes, and nonzero pad bits.
        auto canonical = urlSafe ? Base64URL.encode(bytes) : Base64.encode(bytes);
        if (canonical != text)
            fail("E_RUNTIME", "base64.decode needs canonical padded Base64", l);
        return Value(cast(string) bytes.idup);
    });
    return modules;
}

private Value fromJSON(JSONValue value, Location loc, size_t depth = 0) @safe
{
    if (depth >= 256 && (value.type == JSONType.array || value.type == JSONType.object))
        fail("E_RUNTIME", "JSON nesting exceeds 256 levels", loc);
    switch (value.type)
    {
    case JSONType.null_:
        return Value.init;
    case JSONType.true_:
        return Value(true);
    case JSONType.false_:
        return Value(false);
    case JSONType.integer:
        return Value(value.integer);
    case JSONType.uinteger:
        if (value.uinteger > long.max)
            fail("E_RUNTIME",
                    "JSON integer is outside the signed 64-bit range", loc);
        return Value(cast(long) value.uinteger);
    case JSONType.float_:
        if (!isFinite(value.floating))
            fail("E_RUNTIME",
                    "JSON number is not finite", loc);
        return Value(value.floating);
    case JSONType.string:
        return Value(value.str);
    case JSONType.array:
        Value[] entries;
        foreach (entry; value.arrayNoRef)
            entries ~= fromJSON(entry, loc, depth + 1);
        return Value(entries);
    case JSONType.object:
        Value[string] fields;
        foreach (key, entry; value.objectNoRef)
            fields[key] = fromJSON(entry, loc, depth + 1);
        return Value(fields);
    default:
        fail("E_TYPE", "unsupported JSON value", loc);
    }
    return Value.init;
}

private JSONValue toJSON(Value value, Location loc, Object[] ancestors = null) @safe
{
    if (ancestors.length >= 256 && (value.kind == Value.Kind.list || value.kind == Value.Kind.map))
        fail("E_RUNTIME", "JSON nesting exceeds 256 levels", loc);
    switch (value.kind)
    {
    case Value.Kind.nil:
        return JSONValue(null);
    case Value.Kind.boolean:
        return JSONValue(value.truth);
    case Value.Kind.integer:
        return JSONValue(value.integer);
    case Value.Kind.floating:
        if (!isFinite(value.number))
            fail("E_RUNTIME",
                    "JSON number is not finite", loc);
        return JSONValue(value.number);
    case Value.Kind.text:
    case Value.Kind.path:
        validate(value.text);
        return JSONValue(value.text);
    case Value.Kind.list:
        if (ancestors.canFind!((a,
                b) => a is b)(value.data.listValue))
            fail("E_RUNTIME", "JSON cannot encode a cyclic list", loc);
        JSONValue[] entries;
        foreach (entry; value.items)
            entries ~= toJSON(entry, loc, ancestors ~ value.data.listValue);
        return JSONValue(entries);
    case Value.Kind.map:
        if (ancestors.canFind!((a,
                b) => a is b)(value.data.mapValue))
            fail("E_RUNTIME", "JSON cannot encode a cyclic map", loc);
        JSONValue[string] fields;
        foreach (key, entry; value.data.mapValue.values)
        {
            validate(key);
            fields[key] = toJSON(entry, loc, ancestors ~ value.data.mapValue);
        }
        return JSONValue(fields);
    default:
        fail("E_TYPE", "JSON cannot encode " ~ value.typeName, loc);
    }
    return JSONValue.init;
}

private string formatJSON(JSONValue value, bool pretty, size_t depth = 0) @safe
{
    if (value.type != JSONType.array && value.type != JSONType.object)
        return value.toString(JSONOptions.doNotEscapeSlashes);
    string[] entries;
    string open, close;
    if (value.type == JSONType.array)
    {
        open = "[";
        close = "]";
        foreach (entry; value.arrayNoRef)
            entries ~= formatJSON(entry, pretty, depth + 1);
    }
    else
    {
        open = "{";
        close = "}";
        foreach (key; value.objectNoRef.keys.sort)
            entries ~= JSONValue(key).toString(JSONOptions.doNotEscapeSlashes) ~ (pretty
                    ? ": " : ":") ~ formatJSON(value.objectNoRef[key], pretty, depth + 1);
    }
    if (!entries.length)
        return open ~ close;
    if (!pretty)
        return open ~ entries.join(",") ~ close;
    string indentation;
    foreach (i; 0 .. depth)
        indentation ~= "  ";
    auto childIndentation = indentation ~ "  ";
    return open ~ "\n" ~ childIndentation ~ entries.join(
            ",\n" ~ childIndentation) ~ "\n" ~ indentation ~ close;
}
