module rattpack.graph.model;

import rattpack.content.hash;
import rattpack.serialization;
import rattpack.diagnostic;
import rattpack.rt.sys : buildProcessEnvironment;
import std.json;
import std.algorithm;
import std.path;
import std.file;
import std.string;
import std.base64;

class Artifact
{
    string path;
    string id;
    string contentHash;
    string producer;
    this(string path) @safe
    {
        this.path = path;
    }
}

class Action
{
    string name;
    string id;
    string[] inputs;
    string[] outputs;
    string[] dependencies;
    string[][] commands;
    string snapshot;
    string settings;
    string cwd;
    string toolchain;
    string[string] environment;
    string[string] tools;
    bool hermetic;
    bool serial;
    bool sandbox = true;
    JSONValue toJSON() @safe
    {
        JSONValue[] commands_;
        foreach (command; commands)
            commands_ ~= JSONValue(command);
        return JSONValue([
            "name": JSONValue(name),
            "id": JSONValue(id),
            "inputs": JSONValue(inputs),
            "outputs": JSONValue(outputs),
            "dependencies": JSONValue(dependencies),
            "commands": JSONValue(commands_),
            "snapshot": JSONValue(snapshot),
            "settings": JSONValue(settings),
            "cwd": JSONValue(cwd),
            "toolchain": JSONValue(toolchain),
            "environment": JSONValue(environment),
            "tools": JSONValue(tools),
            "hermetic": JSONValue(hermetic),
            "serial": JSONValue(serial),
            "sandbox": JSONValue(sandbox)
        ]);
    }

    JSONValue recipeJSON() @safe
    {
        auto fields = toJSON.objectNoRef;
        fields.remove("id");
        fields.remove("dependencies");
        return JSONValue(fields);
    }
}

class Graph
{
    string root;
    string projectName;
    Action[string] actions;
    Artifact[string] artifacts;
    this(string root) @safe
    {
        this.root = buildNormalizedPath(absolutePath(root));
    }

    string normalize(string path) @safe
    {
        if (isAbsolute(path))
        {
            path = buildNormalizedPath(path);
            if (path.startsWith(root ~ dirSeparator))
                return relativePath(path, root).replace("\\", "/");
            return path;
        }
        return buildNormalizedPath(path).replace("\\", "/");
    }

    void add(Action action)
    {
        if (action.name in actions)
            fail("E_TARGET", "duplicate target '" ~ action.name ~ "'");
        if (!action.outputs.length)
            fail("E_TARGET", "target requires an output: " ~ action.name);
        foreach (ref path; action.inputs)
        {
            path = normalize(path);
            if (!(path in artifacts))
                artifacts[path] = new Artifact(path);
        }
        foreach (ref path; action.outputs)
        {
            path = normalize(path);
            if (!(path in artifacts))
                artifacts[path] = new Artifact(path);
            auto node = artifacts[path];
            if (node.producer.length)
                fail("E_TARGET", "multiple actions produce " ~ path);
            node.producer = action.name;
        }
        if (!action.cwd.length)
            action.cwd = root;
        if (!action.environment.length)
            action.environment = buildProcessEnvironment();
        actions[action.name] = action;
    }

    string[] prerequisites(Action action) @safe
    {
        auto names = action.dependencies.dup;
        foreach (path; action.inputs)
            if (artifacts[path].producer.length)
                names ~= artifacts[path].producer;
        names.sort;
        return names.uniq.array;
    }

    Action[] ordered(string[] selected = null) @safe
    {
        Action[] result;
        int[string] state;
        void visit(string name)
        {
            if (!(name in actions))
                fail("E_TARGET", "unknown target '" ~ name ~ "'");
            if (state.get(name, 0) == 1)
                fail("E_CYCLE", "dependency cycle at " ~ name);
            if (state.get(name, 0) == 2)
                return;
            state[name] = 1;
            foreach (dependency; prerequisites(actions[name]))
                visit(dependency);
            state[name] = 2;
            result ~= actions[name];
        }

        if (!selected.length)
            selected = actions.keys.sort.array;
        foreach (name; selected)
            visit(name);
        return result;
    }

    void finalize(bool refreshSources = true)
    {
        if (!actions.length)
            fail("E_SPEC", "project must declare at least one target");
        foreach (node; artifacts.byValue)
            if (!node.producer.length)
            {
                auto path = absolutePath(node.path, root);
                if (refreshSources)
                {
                    if (!exists(path) || !isFile(path))
                        fail("E_TARGET", "input file not found: " ~ node.path);
                    node.contentHash = hashFile(path);
                }
                node.id = hashParts([
                    "rattpack-source-v1", node.path, node.contentHash
                ]);
            }
        foreach (action; ordered)
        {
            string[] parts = [
                "rattpack-action-v1", canonical(action.recipeJSON)
            ];
            foreach (path; action.inputs)
                parts ~= artifacts[path].id;
            foreach (name; prerequisites(action))
                parts ~= actions[name].id;
            action.id = hashParts(parts);
            foreach (path; action.outputs)
                artifacts[path].id = hashParts([
                "rattpack-artifact-v1", path, action.id
            ]);
        }
    }

    JSONValue toJSON() @safe
    {
        JSONValue[] actions_, nodes;
        foreach (name; actions.keys.sort)
            actions_ ~= actions[name].toJSON;
        foreach (path; artifacts.keys.sort)
        {
            auto node = artifacts[path];
            nodes ~= JSONValue([
                "path": JSONValue(path),
                "id": JSONValue(node.id),
                "hash": JSONValue(node.contentHash),
                "producer": JSONValue(node.producer)
            ]);
        }
        return JSONValue([
            "version": JSONValue(2),
            "root": JSONValue(root),
            "project": JSONValue(projectName),
            "actions": JSONValue(actions_),
            "artifacts": JSONValue(nodes)
        ]);
    }

    string digest() @safe
    {
        return hashBytes(canonical(toJSON));
    }

    string toDot() @safe
    {
        string result = "digraph rattpack {\n  // rattpack-v2:" ~ Base64.encode(
                cast(const(ubyte)[]) canonical(toJSON)).idup ~ "\n";
        foreach (path; artifacts.keys.sort)
            result ~= "  " ~ JSONValue(artifacts[path].id)
                .toString ~ " [label=" ~ JSONValue(path).toString ~ "];\n";
        foreach (action; ordered)
        {
            auto id = JSONValue(action.id).toString;
            result ~= "  " ~ id ~ " [shape=box,label=" ~ JSONValue(action.name).toString ~ "];\n";
            foreach (path; action.inputs)
                result ~= "  " ~ JSONValue(artifacts[path].id).toString ~ " -> " ~ id ~ ";\n";
            foreach (path; action.outputs)
                result ~= "  " ~ id ~ " -> " ~ JSONValue(artifacts[path].id).toString ~ ";\n";
            foreach (name; action.dependencies)
                result ~= "  " ~ JSONValue(actions[name].id)
                    .toString ~ " -> " ~ id ~ " [style=dashed];\n";
        }
        return result ~ "}\n";
    }

    static Graph fromJSON(JSONValue document)
    {
        try
        {
            if (document["version"].integer != 2)
                fail("E_GRAPH", "unsupported graph version");
            auto graph = new Graph(document["root"].str);
            graph.projectName = document["project"].str;
            foreach (v; document["actions"].array)
            {
                auto action = new Action;
                action.name = v["name"].str;
                action.id = v["id"].str;
                action.inputs = strings(v["inputs"]);
                action.outputs = strings(v["outputs"]);
                action.dependencies = strings(v["dependencies"]);
                action.snapshot = v["snapshot"].str;
                action.cwd = v["cwd"].str;
                action.settings = v["settings"].str;
                action.toolchain = v["toolchain"].str;
                foreach (key, value; v["environment"].objectNoRef)
                    action.environment[key] = value.str;
                foreach (key, value; v["tools"].objectNoRef)
                    action.tools[key] = value.str;
                action.hermetic = v["hermetic"].type == JSONType.true_;
                action.serial = v["serial"].type == JSONType.true_;
                action.sandbox = v["sandbox"].type == JSONType.true_;
                foreach (command; v["commands"].array)
                    action.commands ~= strings(command);
                graph.add(action);
            }
            foreach (v; document["artifacts"].array)
            {
                auto path = v["path"].str;
                if (!(path in graph.artifacts) || graph.artifacts[path].producer
                        != v["producer"].str)
                    fail("E_GRAPH", "inconsistent artifact producer");
                graph.artifacts[path].contentHash = v["hash"].str;
            }
            graph.finalize(false);
            if (canonical(graph.toJSON) != canonical(document))
                fail("E_GRAPH", "graph identities do not match content");
            return graph;
        }
        catch (Diagnostic d)
        {
            throw d;
        }
        catch (Exception e)
        {
            fail("E_GRAPH", e.msg);
        }
        return null;
    }

    static Graph importGraph(string data)
    {
        try
        {
            if (data.stripLeft.startsWith("{"))
                return fromJSON(parseJSON(data));
            foreach (line; data.splitLines)
            {
                auto marker = line.indexOf("// rattpack-v2:");
                if (marker >= 0)
                    return fromJSON(parseJSON(cast(string) Base64.decode(
                            line[cast(size_t) marker + 15 .. $].strip)));
            }
        }
        catch (Diagnostic d)
        {
            throw d;
        }
        catch (Exception e)
        {
            fail("E_GRAPH", e.msg);
        }
        fail("E_GRAPH", "missing Rattpack graph payload");
        return null;
    }
}

import std.array : array;
