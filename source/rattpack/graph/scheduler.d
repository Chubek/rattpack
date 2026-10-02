module rattpack.graph.scheduler;

import rattpack.graph.model;
import rattpack.graph.hash;
import rattpack.script.snapshot;
import rattpack.script.evaluator;
import rattpack.stdlib.modules;
import rattpack.config.environment;
import rattpack.rt.sys;
import rattpack.diagnostic;
import std.file;
import std.path;
import std.algorithm;
import std.parallelism;
import std.array : array;
import msgpack;
import containers.dynamicarray : DynamicArray;

struct CacheEntry
{
    string recipe;
    string[string] outputs;
}

struct BuildResult
{
    size_t executed;
    size_t skipped;
}

class Scheduler
{
    Graph graph;
    Configuration configuration;
    size_t jobs;
    bool dryRun;
    void delegate(string) output;
    this(Graph graph, Configuration configuration, size_t jobs = 0)
    {
        this.graph = graph;
        this.configuration = configuration;
        this.jobs = jobs ? jobs : cpuCount;
    }

    string cacheDirectory()
    {
        return buildPath(configuration.cacheDirectory, "graphs", hashBytes(graph.root));
    }

    BuildResult build(string[] targets = null)
    {
        graph.finalize;
        auto pending = graph.ordered(targets);
        jobs = min(jobs, max(cast(size_t) 1, pending.length));
        bool[string] done;
        BuildResult result;
        auto cachePath = buildPath(cacheDirectory, "cache.msgpack");
        CacheEntry[string] cache;
        if (exists(cachePath))
            try
            {
                unpack(cast(ubyte[]) read(cachePath), cache);
            }
            catch (Exception)
            {
                cache = null;
            }
        auto pool = new TaskPool(jobs > 1 ? jobs : 1);
        scope (exit)
            pool.finish;
        while (pending.length)
        {
            DynamicArray!Action runnable;
            Action[] remaining;
            foreach (action; pending)
            {
                bool available = true;
                foreach (name; graph.prerequisites(action))
                    if (!done.get(name, false))
                        available = false;
                if (available && runnable.length < jobs && (!action.serial
                        || !runnable.length) && (!runnable.length || !runnable[0].serial))
                    runnable.insertBack(action);
                else
                    remaining ~= action;
            }
            auto ready = runnable[];
            if (!ready.length)
                fail("E_CYCLE", "scheduler has no runnable actions");
            bool[] run;
            run.length = ready.length;
            string[] keys;
            keys.length = ready.length;
            foreach (i, action; ready)
            {
                string[] parts = [action.id];
                foreach (path; action.inputs)
                    parts ~= hashFile(absolutePath(path, graph.root));
                keys[i] = hashParts(parts);
                bool current;
                if (auto entry = action.name in cache)
                {
                    current = entry.recipe == keys[i];
                    foreach (path; action.outputs)
                        if (!exists(absolutePath(path, graph.root))
                                || entry.outputs.get(path,
                                    "") != hashFile(absolutePath(path, graph.root)))
                            current = false;
                }
                run[i] = !current;
                if (current)
                    result.skipped++;
                else
                {
                    result.executed++;
                    if (output !is null)
                        output((dryRun ? "would build " : "build ") ~ action.name);
                }
            }
            Exception[] errors;
            errors.length = ready.length;
            string[] logs;
            logs.length = ready.length;
            foreach (i; pool.parallel(iota(ready.length), 1))
            {
                if (!run[i] || dryRun)
                    continue;
                try
                {
                    executeAction(ready[i], (line) { logs[i] ~= line ~ "\n"; });
                }
                catch (Exception e)
                {
                    errors[i] = e;
                }
            }
            foreach (i, action; ready)
            {
                if (logs[i].length && output !is null)
                    output(logs[i].stripRight);
                if (errors[i]!is null)
                    throw errors[i];
                done[action.name] = true;
                if (run[i] && !dryRun)
                {
                    CacheEntry entry;
                    entry.recipe = keys[i];
                    foreach (path; action.outputs)
                    {
                        auto absolute = absolutePath(path, graph.root);
                        if (!exists(absolute))
                            fail("E_ACTION", "action did not produce " ~ path);
                        entry.outputs[path] = hashFile(absolute);
                    }
                    cache[action.name] = entry;
                    atomicWrite(cachePath, pack(cache));
                }
            }
            pending = remaining;
        }
        return result;
    }

    void runSingle(Action action, bool incremental)
    {
        auto path = buildPath(cacheDirectory, "export", hashBytes(action.name) ~ ".msgpack");
        CacheEntry entry;
        if (incremental && exists(path))
            try
            {
                unpack(cast(ubyte[]) read(path), entry);
            }
            catch (Exception)
            {
            }
        string[] parts = [action.id];
        foreach (input; action.inputs)
            parts ~= hashFile(absolutePath(input, graph.root));
        auto recipe = hashParts(parts);
        bool current = incremental && entry.recipe == recipe;
        foreach (output; action.outputs)
            if (!exists(absolutePath(output, graph.root))
                    || entry.outputs.get(output, "") != hashFile(absolutePath(output, graph.root)))
                current = false;
        if (current)
            return;
        executeAction(action, output);
        entry.recipe = recipe;
        foreach (output; action.outputs)
        {
            auto absolute = absolutePath(output, graph.root);
            if (!exists(absolute))
                fail("E_ACTION", "action did not produce " ~ output);
            entry.outputs[output] = hashFile(absolute);
        }
        if (incremental)
            atomicWrite(path, pack(entry));
    }

    void executeAction(Action action, void delegate(string) log = null)
    {
        string[] writable;
        foreach (path; action.outputs)
        {
            auto directory = dirName(absolutePath(path, graph.root));
            mkdirRecurse(directory);
            writable ~= directory;
        }
        writable.sort;
        writable = writable.uniq.array;
        auto temporary = buildPath(graph.root, ".rattpack", "sandbox", action.id);
        mkdirRecurse(temporary);
        scope (exit)
            if (exists(temporary))
                rmdirRecurse(temporary);
        ProcessResult run(string[] command, string cwd)
        {
            return action.sandbox ? runSandboxed(command, cwd, writable,
                    temporary) : runProcess(command, cwd);
        }

        foreach (command; action.commands)
        {
            auto result = run(command, action.cwd);
            if (result.output.length && log !is null)
                log(result.output.stripRight);
            if (result.status)
                fail("E_ACTION", "command failed for " ~ action.name ~ ": " ~ result.output);
        }
        if (action.snapshot.length)
        {
            auto config = configuration;
            if (action.settings.length)
            {
                auto settings = thaw(new Evaluator, action.settings);
                config = new Configuration(settings.closure.values);
            }
            auto evaluator = new Evaluator(Phase.execution, action.cwd);
            installStdlib(evaluator, config);
            if (action.sandbox)
                evaluator.writeRoots = writable;
            evaluator.processRunner = &run;
            evaluator.output = log;
            foreach (name; [
                "fs", "path", "proc", "str", "env", "toolchain", "log"
            ])
                evaluator.importModule(name, Location("<action>"));
            auto deferred = thaw(evaluator, action.snapshot);
            evaluator.execute(deferred.body, new Environment(deferred.closure));
        }
    }
}

import std.range : iota;
import std.string : stripRight;
