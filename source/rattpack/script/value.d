module rattpack.script.value;

import rattpack.diagnostic;
import taggedalgebraic.taggedunion : TaggedUnion;
import std.algorithm : sort;
import std.conv : to;
import std.string : join;

struct Nil
{
}

struct PathValue
{
    string value;
}

class ListValue
{
    Value[] values;
    this(Value[] values) @safe
    {
        this.values = values;
    }
}

class MapValue
{
    Value[string] values;
    this(Value[string] values) @safe
    {
        this.values = values;
    }
}

final class SetValue
{
    Value[] values;
    this(Value[] values) @safe
    {
        foreach (v; values)
            if (!contains(v))
                this.values ~= v;
    }

    bool contains(Value v) @safe
    {
        foreach (e; values)
            if (equal(e, v))
                return true;
        return false;
    }
}

class HandleValue
{
    string name;
    Value[string] fields;
    this(string name, Value[string] fields = null) @safe
    {
        this.name = name;
        this.fields = fields;
    }
}

struct Arguments
{
    Value[] positional;
    Value[string] named;

    Value get(string name, size_t position, Value fallback = Value.init) @safe
    {
        if (auto value = name in named)
            return *value;
        return position < positional.length ? positional[position] : fallback;
    }
}

abstract class Callable
{
    string name;
    bool effectful;
    Value call(Arguments args, Location location);
}

class Native : Callable
{
    Value delegate(Arguments, Location) implementation;
    bool bound;
    Value receiver;
    string memberName;
    this(string name, Value delegate(Arguments, Location) implementation, bool effectful = false) @safe
    {
        this.name = name;
        this.implementation = implementation;
        this.effectful = effectful;
    }

    override Value call(Arguments args, Location location)
    {
        return implementation(args, location);
    }
}

union Storage
{
    Nil nil;
    bool boolean;
    long integer;
    double floating;
    string text;
    PathValue path;
    ListValue list;
    MapValue map;
    SetValue set;
    Callable function_;
    HandleValue target;
    HandleValue rule;
    HandleValue pkg;
}

struct Value
{
    alias Data = TaggedUnion!Storage;
    alias Kind = Data.Kind;
    Data data;
    @property Kind kind() const @safe
    {
        return data.kind;
    }

    this(bool value) @safe
    {
        data = Data.boolean(value);
    }

    this(long value) @safe
    {
        data = Data.integer(value);
    }

    this(int value) @safe
    {
        data = Data.integer(value);
    }

    this(double value) @safe
    {
        data = Data.floating(value);
    }

    this(string value) @safe
    {
        data = Data.text(value);
    }

    this(Value[] value) @safe
    {
        data = Data.list(new ListValue(value));
    }

    this(Value[string] value) @safe
    {
        data = Data.map(new MapValue(value));
    }

    this(Callable value) @safe
    {
        data = Data.function_(value);
    }

    static Value path(string value) @safe
    {
        Value v;
        v.data = Data.path(PathValue(value));
        return v;
    }

    static Value set(Value[] value) @safe
    {
        Value v;
        v.data = Data.set(new SetValue(value));
        return v;
    }

    static Value handle(Kind kind, string name, Value[string] fields = null) @safe
    {
        Value v;
        auto h = new HandleValue(name, fields);
        if (kind == Kind.target)
            v.data = Data.target(h);
        else if (kind == Kind.rule)
            v.data = Data.rule(h);
        else
            v.data = Data.pkg(h);
        return v;
    }

    bool truth() @safe
    {
        final switch (kind)
        {
        case Kind.nil:
            return false;
        case Kind.boolean:
            return data.booleanValue;
        case Kind.integer:
            return data.integerValue != 0;
        case Kind.floating:
            return data.floatingValue != 0;
        case Kind.text:
            return data.textValue.length != 0;
        case Kind.path:
            return data.pathValue.value.length != 0;
        case Kind.list:
            return data.listValue.values.length != 0;
        case Kind.map:
            return data.mapValue.values.length != 0;
        case Kind.set:
            return data.setValue.values.length != 0;
        case Kind.function_:
        case Kind.target:
        case Kind.rule:
        case Kind.pkg:
            return true;
        }
    }

    string typeName() const @safe
    {
        final switch (kind)
        {
        case Kind.nil:
            return "nil";
        case Kind.boolean:
            return "bool";
        case Kind.integer:
            return "int";
        case Kind.floating:
            return "float";
        case Kind.text:
            return "str";
        case Kind.path:
            return "path";
        case Kind.list:
            return "list";
        case Kind.map:
            return "map";
        case Kind.set:
            return "set";
        case Kind.function_:
            return "fn";
        case Kind.target:
            return "target";
        case Kind.rule:
            return "rule";
        case Kind.pkg:
            return "pkg";
        }
    }

    string str() @safe
    {
        final switch (kind)
        {
        case Kind.nil:
            return "nil";
        case Kind.boolean:
            return data.booleanValue ? "true" : "false";
        case Kind.integer:
            return data.integerValue.to!string;
        case Kind.floating:
            return data.floatingValue.to!string;
        case Kind.text:
            return data.textValue;
        case Kind.path:
            return data.pathValue.value;
        case Kind.list:
            string[] entries;
            foreach (v; data.listValue.values)
                entries ~= v.str;
            return "[" ~ entries.join(", ") ~ "]";
        case Kind.map:
            string[] entries;
            foreach (key; data.mapValue.values.keys.sort)
                entries ~= key ~ ": " ~ data.mapValue.values[key].str;
            return "{" ~ entries.join(", ") ~ "}";
        case Kind.set:
            string[] entries;
            foreach (v; data.setValue.values)
                entries ~= v.str;
            entries.sort;
            return "set(" ~ entries.join(", ") ~ ")";
        case Kind.function_:
            return "<fn " ~ data.function_Value.name ~ ">";
        case Kind.target:
            return data.targetValue.name;
        case Kind.rule:
            return data.ruleValue.name;
        case Kind.pkg:
            return data.pkgValue.name;
        }
    }

    string text(Location location = Location.init) @safe
    {
        if (kind == Kind.text)
            return data.textValue;
        if (kind == Kind.path)
            return data.pathValue.value;
        fail("E_TYPE", "expected str or path, got " ~ typeName, location);
        return null;
    }

    long integer(Location location = Location.init) @safe
    {
        if (kind == Kind.integer)
            return data.integerValue;
        fail("E_TYPE", "expected int, got " ~ typeName, location);
        return 0;
    }

    double number(Location location = Location.init) @safe
    {
        if (kind == Kind.integer)
            return cast(double) data.integerValue;
        if (kind == Kind.floating)
            return data.floatingValue;
        fail("E_TYPE", "expected number, got " ~ typeName, location);
        return 0;
    }

    Value[] items(Location location = Location.init) @safe
    {
        if (kind == Kind.list)
            return data.listValue.values;
        if (kind == Kind.set)
            return data.setValue.values;
        fail("E_TYPE", "expected list or set, got " ~ typeName, location);
        return null;
    }
}

bool equal(Value a, Value b) @safe
{
    if (a.kind != b.kind)
    {
        if ((a.kind == Value.Kind.integer || a.kind == Value.Kind.floating)
                && (b.kind == Value.Kind.integer || b.kind == Value.Kind.floating))
            return a.number == b.number;
        return false;
    }
    final switch (a.kind)
    {
    case Value.Kind.nil:
        return true;
    case Value.Kind.boolean:
        return a.data.booleanValue == b.data.booleanValue;
    case Value.Kind.integer:
        return a.integer == b.integer;
    case Value.Kind.floating:
        return a.number == b.number;
    case Value.Kind.text:
    case Value.Kind.path:
        return a.text == b.text;
    case Value.Kind.list:
        auto av = a.items, bv = b.items;
        if (av.length != bv.length)
            return false;
        foreach (i, v; av)
            if (!equal(v, bv[i]))
                return false;
        return true;
    case Value.Kind.map:
        auto av = a.data.mapValue.values, bv = b.data.mapValue.values;
        if (av.length != bv.length)
            return false;
        foreach (k, v; av)
        {
            auto other = k in bv;
            if (other is null || !equal(v, *other))
                return false;
        }
        return true;
    case Value.Kind.set:
        if (a.items.length != b.items.length)
            return false;
        foreach (v; a.items)
            if (!b.data.setValue.contains(v))
                return false;
        return true;
    case Value.Kind.function_:
        return a.data.function_Value is b.data.function_Value;
    case Value.Kind.target:
        return a.data.targetValue.name == b.data.targetValue.name;
    case Value.Kind.rule:
        return a.data.ruleValue.name == b.data.ruleValue.name;
    case Value.Kind.pkg:
        return a.data.pkgValue.name == b.data.pkgValue.name;
    }
}
