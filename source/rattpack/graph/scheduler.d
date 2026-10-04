module rattpack.graph.scheduler;

import rattpack.graph.model;
import rattpack.content.hash;
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
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

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
    bool hermetic;
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
        bool strict = hermetic;
        foreach (action; graph.actions.byValue)
            strict = strict || action.hermetic;
        graph.finalize(!strict);
        auto pending = graph.ordered(targets);
        foreach (action; pending)
            validateHermetic(action);
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
        auto workerCount = min(jobs, max(cast(size_t) 1, pending.length));
        auto pool = new TaskPool(workerCount);
        scope (exit)
        {
            // finish(true) can execute queued work on the calling thread. Stop
            // the queue first, then join actions already running on workers.
            pool.stop;
            pool.finish(true);
        }
        auto mutex = new Mutex;
        auto completed = new Condition(mutex);
        bool[] started, finished, collected;
        started.length = finished.length = collected.length = pending.length;
        Throwable[] errors;
        errors.length = pending.length;
        string[] logs, keys;
        logs.length = keys.length = pending.length;
        size_t active, remaining = pending.length;
        bool serialActive;
        void worker(size_t index)
        {
            try
            {
                executeAction(pending[index], (line) { logs[index] ~= line ~ "\n"; });
            }
            catch (Throwable error)
            {
                errors[index] = error;
            }
            synchronized (mutex)
            {
                finished[index] = true;
                completed.notifyAll;
            }
        }

        while (remaining)
        {
            synchronized (mutex)
            {
                foreach (i, action; pending)
                    if (finished[i] && !collected[i])
                    {
                        collected[i] = true;
                        active--;
                        remaining--;
                        if (action.serial)
                            serialActive = false;
                        if (logs[i].length && output !is null)
                            output(logs[i].stripRight);
                        if (errors[i]!is null)
                            throw errors[i];
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
                        done[action.name] = true;
                    }
                foreach (i, action; pending)
                {
                    if (started[i] || serialActive || active >= workerCount)
                        continue;
                    bool available = true;
                    foreach (name; graph.prerequisites(action))
                        if (!done.get(name, false))
                            available = false;
                    if (!available || (action.serial && active))
                        continue;
                    string[] parts = [action.id];
                    foreach (path; action.inputs)
                    {
                        auto absolute = absolutePath(path, graph.root);
                        parts ~= dryRun && !exists(absolute) && graph.artifacts[path].producer.length
                            ? graph.artifacts[path].id : hashFile(absolute);
                    }
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
                    started[i] = true;
                    if (current || dryRun)
                    {
                        if (current)
                            result.skipped++;
                        else
                        {
                            result.executed++;
                            if (output !is null)
                                output("would build " ~ action.name);
                        }
                        collected[i] = true;
                        remaining--;
                        done[action.name] = true;
                        continue;
                    }
                    result.executed++;
                    if (output !is null)
                        output("build " ~ action.name);
                    active++;
                    serialActive = action.serial;
                    // put() executes exclusively on the pool's system threads.
                    // The coordinator never participates as an extra worker.
                    pool.put(task(&worker, i));
                }
                if (remaining && !active)
                    fail("E_CYCLE", "scheduler has no runnable actions");
                if (active)
                    completed.wait;
            }
        }
        return result;
    }

    void runSingle(Action action, bool incremental)
    {
        validateHermetic(action);
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

    private void validateHermetic(Action action)
    {
        if (!hermetic && !action.hermetic)
            return;
        if (!action.sandbox)
            fail("E_HERMETIC", "hermetic execution rejects sandbox: false for " ~ action.name);
        foreach (path; action.inputs)
            if (!graph.artifacts[path].producer.length)
            {
                auto absolute = absolutePath(path, graph.root);
                if (!exists(absolute) || hashFile(absolute) != graph.artifacts[path].contentHash)
                    fail("E_HERMETIC", "frozen graph input changed: " ~ path);
            }
        foreach (tool, fingerprint; action.tools)
            if (!exists(tool) || hashFile(tool) != fingerprint)
                fail("E_HERMETIC", "frozen graph tool changed: " ~ tool);
    }

    void executeAction(Action action, void delegate(string) log = null)
    {
        auto strict = hermetic || action.hermetic;
        if (strict && !action.sandbox)
            fail("E_HERMETIC", "hermetic execution rejects sandbox: false for " ~ action.name);
        string[] readable;
        string[] inputHashes;
        foreach (path; action.inputs)
        {
            auto absolute = buildNormalizedPath(absolutePath(path, graph.root));
            readable ~= absolute;
            inputHashes ~= hashFile(absolute);
            if (strict && !graph.artifacts[path].producer.length
                    && graph.artifacts[path].contentHash != inputHashes[$ - 1])
                fail("E_HERMETIC", "frozen graph input changed: " ~ path);
        }
        if (strict)
            foreach (tool, fingerprint; action.tools)
                if (!exists(tool) || hashFile(tool) != fingerprint)
                    fail("E_HERMETIC", "frozen graph tool changed: " ~ tool);
        string[] writable, outputs;
        foreach (path; action.outputs)
        {
            auto absolute = buildNormalizedPath(absolutePath(path, graph.root));
            if (strict && !absolute.startsWith(graph.root ~ dirSeparator))
                fail("E_HERMETIC", "hermetic outputs must be inside the project: " ~ path);
            outputs ~= absolute;
            auto directory = dirName(absolute);
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
            if (strict)
            {
                auto program = findProgram(command[0], action.environment.get("PATH", ""));
                if (!(program in action.tools))
                    fail("E_HERMETIC", "undeclared action tool: " ~ command[0]);
                auto argv = command.dup;
                argv[0] = program;
                auto result = runHermetic(argv, cwd, writable, temporary,
                        readable ~ action.tools.keys, action.environment);
                if (!result.status)
                    foreach (i, directory; writable)
                        foreach (file; outputs)
                            if (dirName(file) == directory)
                            {
                                import std.conv : to;

                                auto stage = buildPath(temporary, "outputs",
                                        i.to!string, baseName(file));
                                if (exists(stage))
                                {
                                    if (!isFile(stage) || isSymlink(stage))
                                        fail("E_HERMETIC",
                                                "action output must be a regular file: " ~ file);
                                    atomicWrite(file, read(stage));
                                    setExecutable(file, executableFile(stage));
                                }
                            }
                return result;
            }
            return action.sandbox ? runSandboxed(command, cwd, writable,
                    temporary, action.environment) : runProcess(command, cwd);
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
            evaluator.hermetic = strict;
            evaluator.readableFiles = readable;
            evaluator.writableFiles = outputs;
            evaluator.environmentFrozen = action.sandbox;
            evaluator.processEnvironment = action.environment;
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
        if (strict)
            foreach (i, input; readable)
                if (hashFile(input) != inputHashes[i])
                    fail("E_HERMETIC", "action input changed during execution: " ~ input);
    }
}

import std.string : stripRight;
