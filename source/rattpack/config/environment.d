module rattpack.config.environment;

import rattpack.script.value;
import rattpack.diagnostic;
import rattpack.rt.sys;
import std.file;
import std.path;
import toml;
import dyaml;

class Configuration
{
    Value[string] values;
    string directory;
    this(Value[string] values, string directory = null)
    {
        this.values = values;
        this.directory = directory.length ? directory : buildPath(configHome, "rattpack");
    }

    this(string directory = null, bool warningsAsErrors = false, WarningSink sink = null)
    {
        this.directory = directory.length ? directory : buildPath(configHome, "rattpack");
        values = [
            "toolchain.c": Value("cc"),
            "toolchain.cxx": Value("c++"),
            "toolchain.d": Value("ldc2"),
            "build.jobs": Value(0),
            "build.cache_dir": Value(buildPath(cacheHome, "rattpack")),
            "pkg.registry": Value("https://pkgs.example.org"),
            "pkg.mirrors": Value(cast(Value[])[]),
            "user.name": Value(userName),
            "user.email": Value(""),
            "user.license": Value("MIT")
        ];
        auto tomlPath = buildPath(this.directory, "Config.toml");
        auto yamlPath = buildPath(this.directory, "Config.yaml");
        if (exists(tomlPath) && exists(yamlPath))
            warning("W_DUAL_CONFIG", "Config.toml takes precedence over Config.yaml",
                    Location(tomlPath), warningsAsErrors, sink);
        try
        {
            if (exists(tomlPath))
                flattenToml(parseTOML(readText(tomlPath)).table, "");
            else if (exists(yamlPath))
                flattenYaml(Loader.fromFile(yamlPath).load, "");
        }
        catch (Diagnostic d)
        {
            throw d;
        }
        catch (Exception e)
        {
            fail("E_CONFIG", e.msg, Location(exists(tomlPath) ? tomlPath : yamlPath));
        }
    }

    Value get(string key, Value fallback = Value.init) @safe
    {
        return copySetting(values.get(key, fallback));
    }

    string text(string key, string fallback = "") @safe
    {
        auto v = get(key);
        return v.kind == Value.Kind.nil ? fallback : v.text;
    }

    string cacheDirectory()
    {
        auto directory = text("build.cache_dir", buildPath(cacheHome, "rattpack"));
        import std.process : environment;

        if (directory.length && directory[0] == '~')
            directory = environment.get("HOME", ".") ~ directory[1 .. $];
        return absolutePath(directory);
    }

    private void flattenToml(TOMLValue[string] table, string prefix)
    {
        foreach (key, value; table)
        {
            auto name = prefix.length ? prefix ~ "." ~ key : key;
            if (value.type == TOML_TYPE.TABLE)
                flattenToml(value.table, name);
            else
                values[name] = fromToml(value);
        }
    }

    private void flattenYaml(Node node, string prefix)
    {
        if (node.nodeID == NodeID.mapping)
            foreach (Node key, Node value; node)
            {
                auto name = prefix.length ? prefix ~ "." ~ key.as!string : key.as!string;
                if (value.nodeID == NodeID.mapping)
                    flattenYaml(value, name);
                else
                    values[name] = fromYaml(value);
            }
        else
            fail("E_CONFIG", "configuration must be a mapping");
    }
}

Value fromToml(TOMLValue value)
{
    switch (value.type)
    {
    case TOML_TYPE.STRING:
        return Value(value.str);
    case TOML_TYPE.INTEGER:
        return Value(value.integer);
    case TOML_TYPE.FLOAT:
        return Value(cast(double) value.floating);
    case TOML_TYPE.TRUE:
    case TOML_TYPE.FALSE:
        return Value(value.boolean);
    case TOML_TYPE.ARRAY:
        Value[] values;
        foreach (v; value.array)
            values ~= fromToml(v);
        return Value(values);
    case TOML_TYPE.TABLE:
        Value[string] values;
        foreach (k, v; value.table)
            values[k] = fromToml(v);
        return Value(values);
    default:
        return Value(value.toString);
    }
}

private Value fromYaml(Node node)
{
    if (node.nodeID == NodeID.mapping)
    {
        Value[string] values;
        foreach (Node key, Node value; node)
            values[key.as!string] = fromYaml(value);
        return Value(values);
    }
    if (node.nodeID == NodeID.sequence)
    {
        Value[] values;
        foreach (Node v; node)
            values ~= fromYaml(v);
        return Value(values);
    }
    if (node.tag == "tag:yaml.org,2002:bool")
        return Value(node.as!bool);
    if (node.tag == "tag:yaml.org,2002:int")
        return Value(node.as!long);
    if (node.tag == "tag:yaml.org,2002:float")
        return Value(node.as!double);
    if (node.tag == "tag:yaml.org,2002:null")
        return Value.init;
    return Value(node.as!string);
}

private Value copySetting(Value value) @safe
{
    if (value.kind == Value.Kind.list || value.kind == Value.Kind.set)
    {
        Value[] values;
        foreach (entry; value.items)
            values ~= copySetting(entry);
        return value.kind == Value.Kind.list ? Value(values) : Value.set(values);
    }
    if (value.kind == Value.Kind.map)
    {
        Value[string] values;
        foreach (key, entry; value.data.mapValue.values)
            values[key] = copySetting(entry);
        return Value(values);
    }
    return value;
}
