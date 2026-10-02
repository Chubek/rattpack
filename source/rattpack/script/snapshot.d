module rattpack.script.snapshot;

import rattpack.script.ast;
import rattpack.script.value;
import rattpack.script.evaluator;
import rattpack.serialization;
import rattpack.diagnostic;
import std.json;
import std.algorithm : sort;

@safe:

private JSONValue locationJSON(Location l)
{
    return JSONValue([JSONValue(l.file), JSONValue(l.line), JSONValue(l.column)]);
}

private Location locationFrom(JSONValue v)
{
    return Location(v.arrayNoRef[0].str, cast(size_t) v.arrayNoRef[1].integer,
            cast(size_t) v.arrayNoRef[2].integer);
}

private JSONValue paramsJSON(Parameter[] parameters)
{
    JSONValue[] values;
    foreach (p; parameters)
        values ~= JSONValue([
        "name": JSONValue(p.name),
        "type": JSONValue(p.annotation),
        "default": exprJSON(p.defaultValue)
    ]);
    return JSONValue(values);
}

private Parameter[] paramsFrom(JSONValue value)
{
    Parameter[] result;
    foreach (v; value.arrayNoRef)
        result ~= Parameter(v["name"].str, v["type"].str, exprFrom(v["default"]));
    return result;
}

private double numberFrom(JSONValue value)
{
    return value.type == JSONType.float_ ? value.floating : cast(double) value.integer;
}

private JSONValue exprJSON(Expr e)
{
    if (e is null)
        return JSONValue(null);
    JSONValue[] entries;
    foreach (entry; e.entries)
        entries ~= exprJSON(entry);
    auto v = JSONValue([
        "kind": JSONValue(cast(int) e.kind),
        "location": locationJSON(e.location),
        "text": JSONValue(e.text),
        "left": exprJSON(e.left),
        "right": exprJSON(e.right),
        "entries": JSONValue(entries),
        "names": JSONValue(e.names),
        "parameters": paramsJSON(e.parameters),
        "body": stmtJSON(e.body)
    ]);
    if (e.kind == ExprKind.literal)
    {
        v["type"] = JSONValue(e.literal.typeName);
        switch (e.literal.kind)
        {
        case Value.Kind.boolean:
            v["value"] = JSONValue(e.literal.truth);
            break;
        case Value.Kind.integer:
            v["value"] = JSONValue(e.literal.integer);
            break;
        case Value.Kind.floating:
            v["value"] = JSONValue(e.literal.number);
            break;
        case Value.Kind.text:
            v["value"] = JSONValue(e.literal.text);
            break;
        default:
            v["value"] = JSONValue(null);
        }
    }
    return v;
}

private Expr exprFrom(JSONValue v)
{
    if (v.type == JSONType.null_)
        return null;
    auto e = new Expr(cast(ExprKind) v["kind"].integer, locationFrom(v["location"]));
    e.text = v["text"].str;
    e.left = exprFrom(v["left"]);
    e.right = exprFrom(v["right"]);
    foreach (entry; v["entries"].arrayNoRef)
        e.entries ~= exprFrom(entry);
    e.names = strings(v["names"]);
    e.parameters = paramsFrom(v["parameters"]);
    e.body = stmtFrom(v["body"]);
    if (e.kind == ExprKind.literal)
    {
        switch (v["type"].str)
        {
        case "bool":
            e.literal = Value(v["value"].type == JSONType.true_);
            break;
        case "int":
            e.literal = Value(v["value"].integer);
            break;
        case "float":
            e.literal = Value(numberFrom(v["value"]));
            break;
        case "str":
            e.literal = Value(v["value"].str);
            break;
        default:
            break;
        }
    }
    return e;
}

private JSONValue stmtJSON(Stmt s)
{
    if (s is null)
        return JSONValue(null);
    JSONValue[] statements;
    foreach (child; s.statements)
        statements ~= stmtJSON(child);
    return JSONValue([
        "kind": JSONValue(cast(int) s.kind),
        "location": locationJSON(s.location),
        "name": JSONValue(s.name),
        "type": JSONValue(s.annotation),
        "expression": exprJSON(s.expression),
        "extra": exprJSON(s.extra),
        "body": stmtJSON(s.body),
        "otherwise": stmtJSON(s.otherwise),
        "statements": JSONValue(statements),
        "parameters": paramsJSON(s.parameters)
    ]);
}

private Stmt stmtFrom(JSONValue v)
{
    if (v.type == JSONType.null_)
        return null;
    auto s = new Stmt(cast(StmtKind) v["kind"].integer, locationFrom(v["location"]));
    s.name = v["name"].str;
    s.annotation = v["type"].str;
    s.expression = exprFrom(v["expression"]);
    s.extra = exprFrom(v["extra"]);
    s.body = stmtFrom(v["body"]);
    s.otherwise = stmtFrom(v["otherwise"]);
    s.parameters = paramsFrom(v["parameters"]);
    foreach (child; v["statements"].arrayNoRef)
        s.statements ~= stmtFrom(child);
    return s;
}

private class Freezer
{
    size_t[Object] ids;
    JSONValue[] objects;
    size_t reference(Object o)
    {
        if (auto id = o in ids)
            return *id;
        auto id = objects.length;
        ids[o] = id;
        objects ~= JSONValue(null);
        auto v = jsonObject();
        if (auto env = cast(Environment) o)
        {
            v["kind"] = JSONValue("scope");
            v["parent"] = env.parent is null ? JSONValue(null) : JSONValue(reference(env.parent));
            auto values = jsonObject();
            foreach (key; env.values.keys.sort)
                values[key] = encode(env.values[key]);
            v["values"] = values;
            v["types"] = JSONValue(env.annotations);
        }
        else if (auto f = cast(UserFunction) o)
        {
            v["kind"] = JSONValue("function");
            v["name"] = JSONValue(f.name);
            v["type"] = JSONValue(f.annotation);
            v["scope"] = JSONValue(reference(f.closure));
            v["parameters"] = paramsJSON(f.parameters);
            v["body"] = stmtJSON(f.body);
        }
        else if (auto n = cast(Native) o)
        {
            v["kind"] = JSONValue("native");
            v["name"] = JSONValue(n.name);
            v["bound"] = JSONValue(n.bound);
            if (n.bound)
            {
                v["receiver"] = encode(n.receiver);
                v["member"] = JSONValue(n.memberName);
            }
        }
        else if (auto m = cast(MapValue) o)
        {
            v["kind"] = JSONValue("map");
            auto values = jsonObject();
            foreach (key; m.values.keys.sort)
                values[key] = encode(m.values[key]);
            v["values"] = values;
        }
        else if (auto h = cast(HandleValue) o)
        {
            v["kind"] = JSONValue("handle");
            v["name"] = JSONValue(h.name);
            auto fields = jsonObject();
            foreach (key; h.fields.keys.sort)
                fields[key] = encode(h.fields[key]);
            v["values"] = fields;
        }
        else
        {
            Value[] entries;
            if (auto list = cast(ListValue) o)
            {
                v["kind"] = JSONValue("list");
                entries = list.values;
            }
            else if (auto set = cast(SetValue) o)
            {
                v["kind"] = JSONValue("set");
                entries = set.values;
            }
            JSONValue[] values;
            foreach (entry; entries)
                values ~= encode(entry);
            v["values"] = JSONValue(values);
        }
        objects[id] = v;
        return id;
    }

    JSONValue encode(Value value)
    {
        auto v = JSONValue(["type": JSONValue(value.typeName)]);
        final switch (value.kind)
        {
        case Value.Kind.nil:
            v["value"] = JSONValue(null);
            break;
        case Value.Kind.boolean:
            v["value"] = JSONValue(value.truth);
            break;
        case Value.Kind.integer:
            v["value"] = JSONValue(value.integer);
            break;
        case Value.Kind.floating:
            v["value"] = JSONValue(value.number);
            break;
        case Value.Kind.text:
        case Value.Kind.path:
            v["value"] = JSONValue(value.text);
            break;
        case Value.Kind.list:
            v["ref"] = JSONValue(reference(value.data.listValue));
            break;
        case Value.Kind.map:
            v["ref"] = JSONValue(reference(value.data.mapValue));
            break;
        case Value.Kind.set:
            v["ref"] = JSONValue(reference(value.data.setValue));
            break;
        case Value.Kind.function_:
            v["ref"] = JSONValue(reference(value.data.function_Value));
            break;
        case Value.Kind.target:
            v["ref"] = JSONValue(reference(value.data.targetValue));
            break;
        case Value.Kind.rule:
            v["ref"] = JSONValue(reference(value.data.ruleValue));
            break;
        case Value.Kind.pkg:
            v["ref"] = JSONValue(reference(value.data.pkgValue));
            break;
        }
        return v;
    }
}

string freeze(DeferredAction action)
{
    auto f = new Freezer;
    auto scopeID = f.reference(action.closure);
    return canonical(JSONValue([
        "body": stmtJSON(action.body),
        "scope": JSONValue(scopeID),
        "objects": JSONValue(f.objects)
    ]));
}

private Native unavailableNative(string name)
{
    return new Native(name, (a, l) {
        fail("E_PHASE_VIOLATION", name ~ " is unavailable during execution", l);
        return Value.init;
    });
}

private void restoreBound(Evaluator evaluator, Native native, Value receiver, string memberName)
{
    native.bound = true;
    native.receiver = receiver;
    native.memberName = memberName;
    native.implementation = (a, l) => evaluator.invoke(evaluator.member(receiver,
            memberName, l), a, l);
}

DeferredAction thaw(Evaluator evaluator, string snapshot)
{
    auto document = parseJSON(snapshot);
    auto entries = document["objects"].arrayNoRef;
    Object[] objects;
    objects.length = entries.length;
    foreach (i, v; entries)
    {
        switch (v["kind"].str)
        {
        case "scope":
            objects[i] = new Environment;
            break;
        case "function":
            objects[i] = new UserFunction(evaluator, null, v["name"].str,
                    paramsFrom(v["parameters"]), stmtFrom(v["body"]), v["type"].str);
            break;
        case "native":
            auto name = v["name"].str;
            if (v["bound"].type != JSONType.true_ && name in evaluator.natives)
                objects[i] = evaluator.natives[name];
            else
                objects[i] = unavailableNative(name);
            break;
        case "map":
            objects[i] = new MapValue(null);
            break;
        case "list":
            objects[i] = new ListValue(null);
            break;
        case "set":
            objects[i] = new SetValue(null);
            break;
        case "handle":
            objects[i] = new HandleValue(v["name"].str);
            break;
        default:
            fail("E_GRAPH", "invalid snapshot object");
        }
    }
    Value decode(JSONValue v)
    {
        Value value;
        switch (v["type"].str)
        {
        case "nil":
            return value;
        case "bool":
            return Value(v["value"].type == JSONType.true_);
        case "int":
            return Value(v["value"].integer);
        case "float":
            return Value(numberFrom(v["value"]));
        case "str":
            return Value(v["value"].str);
        case "path":
            return Value.path(v["value"].str);
        case "list":
            value.data = Value.Data.list(cast(ListValue) objects[cast(size_t) v["ref"].integer]);
            break;
        case "map":
            value.data = Value.Data.map(cast(MapValue) objects[cast(size_t) v["ref"].integer]);
            break;
        case "set":
            value.data = Value.Data.set(cast(SetValue) objects[cast(size_t) v["ref"].integer]);
            break;
        case "fn":
            value = Value(cast(Callable) objects[cast(size_t) v["ref"].integer]);
            break;
        case "target":
            value.data = Value.Data.target(cast(HandleValue) objects[cast(size_t) v["ref"].integer]);
            break;
        case "rule":
            value.data = Value.Data.rule(cast(HandleValue) objects[cast(size_t) v["ref"].integer]);
            break;
        case "pkg":
            value.data = Value.Data.pkg(cast(HandleValue) objects[cast(size_t) v["ref"].integer]);
            break;
        default:
            fail("E_GRAPH", "invalid snapshot value");
        }
        return value;
    }

    foreach (i, v; entries)
    {
        if (auto env = cast(Environment) objects[i])
        {
            if (v["parent"].type != JSONType.null_)
                env.parent = cast(Environment) objects[cast(size_t) v["parent"].integer];
            foreach (key, entry; v["values"].objectNoRef)
                env.values[key] = decode(entry);
            foreach (key, entry; v["types"].objectNoRef)
                env.annotations[key] = entry.str;
        }
        else if (auto f = cast(UserFunction) objects[i])
            f.closure = cast(Environment) objects[cast(size_t) v["scope"].integer];
        else if (auto m = cast(MapValue) objects[i])
            foreach (key, entry; v["values"].objectNoRef)
                m.values[key] = decode(entry);
        else if (auto h = cast(HandleValue) objects[i])
                    foreach (key, entry; v["values"].objectNoRef)
                        h.fields[key] = decode(entry);
                else if (auto list = cast(ListValue) objects[i])
                            foreach (entry; v["values"].arrayNoRef)
                                list.values ~= decode(entry);
                        else if (auto set = cast(SetValue) objects[i])
                                    foreach (entry; v["values"].arrayNoRef)
                                        set.values ~= decode(entry);
                                else if (auto native = cast(Native) objects[i])
                                        {
                                            if (v["bound"].type == JSONType.true_)
                                            {
                                                restoreBound(evaluator, native,
                                                        decode(v["receiver"]), v["member"].str);
                                            }
                                        }
    }
    return DeferredAction(Value.init, stmtFrom(document["body"]),
            cast(Environment) objects[cast(size_t) document["scope"].integer]);
}
