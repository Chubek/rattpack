module rattpack.serialization;

import std.json;
import std.algorithm : sort;
import std.string : join;
import std.conv : to;

string canonical(JSONValue value) @safe
{
    if (value.type == JSONType.object)
    {
        string[] fields;
        foreach (key; value.objectNoRef.keys.sort)
            fields ~= JSONValue(key).toString ~ ":" ~ canonical(value.objectNoRef[key]);
        return "{" ~ fields.join(",") ~ "}";
    }
    if (value.type == JSONType.array)
    {
        string[] entries;
        foreach (entry; value.arrayNoRef)
            entries ~= canonical(entry);
        return "[" ~ entries.join(",") ~ "]";
    }
    return value.toString;
}

JSONValue jsonObject() @safe
{
    return JSONValue(cast(JSONValue[string]) null);
}

JSONValue array() @safe
{
    return JSONValue(cast(JSONValue[])[]);
}

string jsonString(JSONValue value, string key, string fallback = "") @safe
{
    auto v = key in value.objectNoRef;
    return v is null ? fallback : v.str;
}

string[] strings(JSONValue value) @safe
{
    string[] result;
    foreach (v; value.arrayNoRef)
        result ~= v.str;
    return result;
}
