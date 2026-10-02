module rattpack.plugin.exporters;

import rattpack.plugin.abi;
import rattpack.graph.model;
import rattpack.serialization;
import rattpack.rt.sys;
import rattpack.diagnostic;
import std.path;
import std.string;
import std.algorithm;
import std.json;
import std.conv : to;
import std.file;

RattPluginV1 builtinExporter(string name)
{
    RattPluginV1 plugin;
    plugin.kind = PluginKind.exporter;
    plugin.name = name;
    switch (name)
    {
    case "cmake":
        plugin.exportGraph = &exportCmake;
        break;
    case "gnumake":
    case "make":
        plugin.exportGraph = &exportMake;
        break;
    case "ninja":
        plugin.exportGraph = &exportNinja;
        break;
    case "meson":
        plugin.exportGraph = &exportMeson;
        break;
    default:
        fail("E_PLUGIN_ABI", "unknown exporter '" ~ name ~ "'");
    }
    return plugin;
}

private string graphFile(Graph graph, string destination)
{
    mkdirRecurse(destination);
    auto path = absolutePath(buildPath(destination, "rattgraph.json"));
    atomicWrite(path, canonical(graph.toJSON));
    return path;
}

private string label(Action action)
{
    return "ratt_" ~ action.id[0 .. 16];
}

private string q(string value)
{
    return JSONValue(value).toString.replace("$", "\\$");
}

private string makeEscape(string value)
{
    return value.replace("$", "$$").replace("#", "\\#").replace(" ", "\\ ").replace(":", "\\:");
}

private string ninjaEscape(string value)
{
    return value.replace("$", "$$").replace(" ", "$ ").replace(":", "$:");
}

private string mesonQuote(string value)
{
    return "'" ~ value.replace("\\", "\\\\").replace("'", "\\'") ~ "'";
}

private string[] dependencies(Graph graph, Action action)
{
    string[] result;
    foreach (path; action.inputs)
        result ~= absolutePath(path, graph.root);
    foreach (name; graph.prerequisites(action))
        foreach (path; graph.actions[name].outputs)
            result ~= absolutePath(path, graph.root);
    result.sort;
    import std.array : array;

    return result.uniq.array;
}

int exportCmake(string dagJSON, string destination, string host, out string error)
{
    try
    {
        auto graph = Graph.fromJSON(parseJSON(dagJSON));
        auto path = graphFile(graph, destination);
        string text = "cmake_minimum_required(VERSION 3.20)\nproject(rattpack_export NONE)\n";
        foreach (action; graph.ordered)
        {
            text ~= "add_custom_command(OUTPUT";
            foreach (output; action.outputs)
                text ~= " " ~ q(absolutePath(output, graph.root));
            text ~= "\n  COMMAND " ~ q(host) ~ " __run-action " ~ q(
                    "--graph=" ~ path) ~ " " ~ q("--action=" ~ action.name);
            text ~= "\n  DEPENDS " ~ q(path);
            foreach (input; dependencies(graph, action))
                text ~= " " ~ q(input);
            text ~= "\n  WORKING_DIRECTORY " ~ q(
                    graph.root) ~ "\n  VERBATIM)\nadd_custom_target(" ~ label(
                    action) ~ " ALL DEPENDS";
            foreach (output; action.outputs)
                text ~= " " ~ q(absolutePath(output, graph.root));
            text ~= ")\n";
        }
        foreach (action; graph.ordered)
            foreach (dep; graph.prerequisites(action))
                text ~= "add_dependencies(" ~ label(action) ~ " " ~ label(graph.actions[dep])
                    ~ ")\n";
        atomicWrite(buildPath(destination, "CMakeLists.txt"), text);
        return 0;
    }
    catch (Exception e)
    {
        error = e.msg;
        return 1;
    }
}

int exportMake(string dagJSON, string destination, string host, out string error)
{
    try
    {
        auto graph = Graph.fromJSON(parseJSON(dagJSON));
        auto path = graphFile(graph, destination);
        string text = ".DELETE_ON_ERROR:\n.PHONY: all\nall:";
        foreach (action; graph.ordered)
            foreach (output; action.outputs)
                text ~= " " ~ makeEscape(absolutePath(output, graph.root));
        text ~= "\n";
        foreach (action; graph.ordered)
        {
            foreach (i, output; action.outputs)
            {
                if (i)
                    text ~= " ";
                text ~= makeEscape(absolutePath(output, graph.root));
            }
            text ~= action.outputs.length > 1 ? " &:" : ":";
            text ~= " " ~ makeEscape(path);
            foreach (input; dependencies(graph, action))
                text ~= " " ~ makeEscape(input);
            text ~= "\n\t" ~ (shellQuote(host) ~ " __run-action " ~ shellQuote(
                    "--graph=" ~ path) ~ " " ~ shellQuote("--action=" ~ action.name)).replace("$",
                    "$$") ~ "\n";
        }
        atomicWrite(buildPath(destination, "Makefile"), text);
        return 0;
    }
    catch (Exception e)
    {
        error = e.msg;
        return 1;
    }
}

int exportNinja(string dagJSON, string destination, string host, out string error)
{
    try
    {
        auto graph = Graph.fromJSON(parseJSON(dagJSON));
        auto path = graphFile(graph, destination);
        string text = "ninja_required_version = 1.10\n";
        foreach (action; graph.ordered)
        {
            text ~= "rule " ~ label(action) ~ "\n  command = " ~ (shellQuote(host) ~ " __run-action " ~ shellQuote(
                    "--graph=" ~ path) ~ " " ~ shellQuote("--action=" ~ action.name)).replace("$",
                    "$$");
            text ~= "\n  description = " ~ action.name.replace("$", "$$") ~ "\n  restat = 1\nbuild";
            foreach (output; action.outputs)
                text ~= " " ~ ninjaEscape(absolutePath(output, graph.root));
            text ~= ": " ~ label(action);
            foreach (input; dependencies(graph, action))
                text ~= " " ~ ninjaEscape(input);
            text ~= " | " ~ ninjaEscape(path) ~ "\n";
        }
        text ~= "build all: phony";
        foreach (action; graph.ordered)
            foreach (output; action.outputs)
                text ~= " " ~ ninjaEscape(absolutePath(output, graph.root));
        text ~= "\ndefault all\n";
        atomicWrite(buildPath(destination, "build.ninja"), text);
        return 0;
    }
    catch (Exception e)
    {
        error = e.msg;
        return 1;
    }
}

int exportMeson(string dagJSON, string destination, string host, out string error)
{
    try
    {
        auto graph = Graph.fromJSON(parseJSON(dagJSON));
        auto path = graphFile(graph, destination);
        string text = "project('rattpack-export', meson_version: '>=0.60')\n";
        foreach (action; graph.ordered)
        {
            auto name = label(action);
            text ~= name ~ " = custom_target(" ~ mesonQuote(name) ~ ",\n  output: " ~ mesonQuote(
                    name ~ ".stamp") ~ ",\n  command: [" ~ mesonQuote(
                    host) ~ ", '__run-action', " ~ mesonQuote("--graph=" ~ path) ~ ", " ~ mesonQuote(
                    "--action=" ~ action.name)
                ~ ", '--incremental-action', '--stamp=@OUTPUT@'],\n  depends: [";
            foreach (i, dependency; graph.prerequisites(action))
            {
                if (i)
                    text ~= ", ";
                text ~= label(graph.actions[dependency]);
            }
            text ~= "],\n  build_by_default: true, build_always_stale: true)\n";
        }
        atomicWrite(buildPath(destination, "meson.build"), text);
        return 0;
    }
    catch (Exception e)
    {
        error = e.msg;
        return 1;
    }
}
