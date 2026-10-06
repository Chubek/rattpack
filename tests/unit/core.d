module tests.core;

import unit_threaded;
import rattpack.script.evaluator;
import rattpack.script.parser;
import rattpack.script.lint;
import rattpack.script.value;
import rattpack.script.snapshot;
import rattpack.stdlib.modules;
import rattpack.config.environment;
import rattpack.config.templating;
import rattpack.spec.loader;
import rattpack.graph.model;
import rattpack.graph.scheduler;
import rattpack.graph.hash;
import rattpack.pkg.lockfile;
import rattpack.plugin.abi;
import rattpack.plugin.loader;
import rattpack.diagnostic;
import rattpack.rt.sys;
import rattpack.serialization : jsonObject;
import std.file;
import std.path;
import std.random : uniform;
import std.conv : to;
import std.json;
import std.algorithm : canFind;
import std.string : replace, startsWith;

private class Fixture
{
    string root;
    Configuration config;
    this()
    {
        root = buildPath(exists("/tmp/opencode") ? "/tmp/opencode" : tempDir,
                "rattpack-unit-" ~ uniform(0UL, ulong.max).to!string);
        mkdirRecurse(root);
        config = new Configuration(buildPath(root, "config"));
        config.values["build.cache_dir"] = Value(buildPath(root, "cache"));
    }

    void close()
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    void put(string path, string text)
    {
        atomicWrite(buildPath(root, path), text);
    }
}

private void expectCode(string code, void delegate() action)
{
    try
    {
        action();
        assert(false, "expected " ~ code);
    }
    catch (Diagnostic d)
    {
        d.code.shouldEqual(code);
    }
}

@("tree walking: recursion, closures, short circuit, and mutation")
unittest
{
    auto evaluator = new Evaluator;
    string result;
    evaluator.output = (line) { result ~= line ~ "\n"; };
    evaluator.run(`
fn fib(n: int) -> int { if n < 2 { return n } return fib(n - 1) + fib(n - 2) }
fn counter() { let n = 0; return fn() { n += 1; return n } }
let next = counter()
let values = [next(), next(), fib(10)]
let lookup = {answer: values[2]}
lookup.answer = lookup.answer + 1
print(values, lookup.answer, false and unknown())
`);
    result.shouldEqual("[1, 2, 55] 56 false\n");
}

@("lint checks annotations in uncalled functions and unreachable branches")
unittest
{
    expectCode("E_TYPE", delegate{
        lint(new Parser(`fn unused(x: int) -> str { return x }`).parse);
    });
    expectCode("E_TYPE", delegate{
        lint(new Parser(`if false { let x: int = "bad" }`).parse);
    });
    lint(new Parser(`fn sum(a: int, b: int) -> int { return a + b } let n: int = sum(3, 4)`).parse);
}

@("construction rejects effectful aliases and imported helper functions")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("helper.ratt", `import "fs"; fn write() { fs.write("bad", "side effect") }`);
    auto evaluator = new Evaluator(Phase.construction, fixture.root);
    installStdlib(evaluator, fixture.config);
    expectCode("E_PHASE_VIOLATION", delegate{
        evaluator.run(`import "./helper.ratt"; helper.write()`,
            buildPath(fixture.root, "entry.ratt"));
    });
    exists(buildPath(fixture.root, "bad")).shouldEqual(false);
}

@("frozen action closures preserve recursion, shared collections, and bound methods")
unittest
{
    auto evaluator = new Evaluator(Phase.construction);
    DeferredAction deferred;
    evaluator.actionHandler = (a) { deferred = a; };
    evaluator.run(`let values = []; let other = []; let alias_ = values; let append = values.append; let appendOther = other.append;
fn count(n) { if n == 0 { return len(alias_) } return count(n - 1) }
action { append(42); appendOther(7); print(count(5), values[0], other[0]) }`);
    auto execution = new Evaluator(Phase.execution);
    string result;
    execution.output = (s) { result ~= s; };
    auto restored = thaw(execution, freeze(deferred));
    execution.execute(restored.body, new Environment(restored.closure));
    result.shouldEqual("1 42 7");
}

@("templates: nested directives and config-first substitution")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.config.values["user.name"] = Value("Ada");
    auto text = preprocess(
            "@if env.get(\"user.name\") == \"Ada\"\n@foreach n in [1, 2]\n@{user.name}:@{n}\n@end\n@else\nwrong\n@end\n",
            fixture.config);
    text.shouldEqual("Ada:1\nAda:2\n");
}

@("TOML wins over YAML and reports both configurations")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("config/Config.toml", "[toolchain]\nc = \"clang\"\n");
    fixture.put("config/Config.yaml", "toolchain:\n  c: gcc\n");
    string code;
    auto config = new Configuration(buildPath(fixture.root, "config"), false, (c, m, l) {
        code = c;
    });
    config.text("toolchain.c").shouldEqual("clang");
    code.shouldEqual("W_DUAL_CONFIG");
    remove(buildPath(fixture.root, "config", "Config.toml"));
    new Configuration(buildPath(fixture.root, "config")).text("toolchain.c").shouldEqual("gcc");
}

@("lint follows template imports and never executes their top-level code")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("entry.ratt.in", `import "./helper.ratt.in"; let n: int = @{40 + 2}`);
    fixture.put("helper.ratt.in", `import "fs"; fs.write("bad", "side effect")
fn unused() -> int { return "wrong" }`);
    auto evaluator = new Evaluator(Phase.construction, fixture.root);
    installStdlib(evaluator, fixture.config);
    expectCode("E_TYPE", delegate{
        lintFile(buildPath(fixture.root, "entry.ratt.in"), evaluator.sourceTransform);
    });
    exists(buildPath(fixture.root, "bad")).shouldEqual(false);
    fixture.put("helper.ratt.in", `import "fs"; fs.write("bad", "side effect")
fn value() -> int { return @{40 + 2} }`);
    lintFile(buildPath(fixture.root, "entry.ratt.in"), evaluator.sourceTransform);
    exists(buildPath(fixture.root, "bad")).shouldEqual(false);
}

@("configuration collections are read-only and actions freeze the config environment")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.config.values["pkg.mirrors"] = Value([Value("original")]);
    fixture.config.values["user.name"] = Value("Ada");
    auto evaluator = new Evaluator(Phase.construction, fixture.root);
    installStdlib(evaluator, fixture.config);
    evaluator.run(`import "env"; let values = env.get("pkg.mirrors"); values.append("changed")`);
    fixture.config.get("pkg.mirrors").items.length.shouldEqual(1UL);
    fixture.put("Rattspec", `project(name: "frozen", version: "1", kind: "single")
import "fs"
import "env"
let configured = rule(name: "configured", output: "build/name")
action(configured) { fs.write("build/name", env.get("user.name")) }`);
    auto graph = new SpecLoader(fixture.root, fixture.config).load;
    fixture.config.values["user.name"] = Value("changed");
    auto restored = Graph.importGraph(graph.toDot);
    new Scheduler(restored, fixture.config, 1).build;
    readText(buildPath(fixture.root, "build/name")).shouldEqual("Ada");
}

@("BLAKE3 matches reference test vectors")
unittest
{
    hashBytes("").shouldEqual("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
    hashBytes("abc").shouldEqual(
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85");
}

@("graph DOT round trips identical action and artifact identities")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("input", "one");
    auto graph = new Graph(fixture.root);
    graph.projectName = "test";
    auto a = new Action;
    a.name = "a";
    a.inputs = ["input"];
    a.outputs = ["build/a"];
    a.commands = [["true"]];
    graph.add(a);
    auto b = new Action;
    b.name = "b";
    b.inputs = ["build/a"];
    b.outputs = ["build/b"];
    b.commands = [["true"]];
    graph.add(b);
    graph.finalize;
    auto restored = Graph.importGraph(graph.toDot);
    restored.digest.shouldEqual(graph.digest);
    restored.artifacts["build/b"].id.shouldEqual(graph.artifacts["build/b"].id);
    auto original = graph.digest;
    fixture.put("input", "two");
    graph.finalize;
    assert(graph.digest != original);
}

@("scheduler detects tampering and content changes without relying on mtimes")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("input", "one");
    fixture.put("Rattspec", `project(name: "test", version: "1.0.0", kind: "single")
import "fs"
let copy = rule(name: "copy", inputs: ["input"], output: "build/output")
action(copy) { fs.write("build/output", fs.read("input")) }`);
    auto graph = new SpecLoader(fixture.root, fixture.config).load;
    auto scheduler = new Scheduler(graph, fixture.config, 2);
    scheduler.build.executed.shouldEqual(1UL);
    scheduler.build.skipped.shouldEqual(1UL);
    fixture.put("build/output", "modified");
    scheduler.build.executed.shouldEqual(1UL);
    auto time = timeLastModified(buildPath(fixture.root, "input"));
    fixture.put("input", "two");
    setTimes(buildPath(fixture.root, "input"), time, time);
    scheduler.build.executed.shouldEqual(1UL);
    readText(buildPath(fixture.root, "build/output")).shouldEqual("two");
}

@("monorepo preserves identities and subordinate module namespaces")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("Rattspec", `project(name: "root", version: "1", kind: "monorepo") monorepo { member "members/one"; vendored "vendor/two"; ignore "old" } rule(name: "root", output: "build/root", command: ["true"])`);
    fixture.put("members/one/Rattspec",
            `project(name: "one", version: "1", kind: "single") rule(name: "same", output: "build/same", command: ["true"])`);
    fixture.put("members/one/sub/Rattspec.m",
            `module(name: "sub") rule(name: "same", output: "build/same", command: ["true"])`);
    fixture.put("vendor/two/Rattspec",
            `project(name: "two", version: "1", kind: "single") rule(name: "same", output: "build/same", command: ["true"])`);
    fixture.put("old/Rattspec", "invalid");
    auto graph = new SpecLoader(fixture.root, fixture.config, true).load;
    graph.actions.length.shouldEqual(4UL);
    assert("one::same" in graph.actions);
    assert("one::sub::same" in graph.actions);
    assert("two::same" in graph.actions);
}

@("lockfile is TOML and round trips immutable package revisions")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    LockedPackage entry;
    entry.name = "example";
    entry.version_ = "1.2.3";
    entry.source = "git";
    entry.url = "https://example.org/a/b";
    entry.revision = "abcdef";
    entry.treeHash = sha256("tree");
    entry.identity = "source";
    auto lock = Lockfile("app", "hash", [entry]);
    writeLock(buildPath(fixture.root, "Rattpkg.lock"), lock);
    auto restored = readLock(buildPath(fixture.root, "Rattpkg.lock"));
    restored.entries[0].revision.shouldEqual("abcdef");
    restored.entries[0].treeHash.shouldEqual(entry.treeHash);
}

@("plugin ABI rejects compiler and version mismatches")
unittest
{
    RattPluginV1 api;
    api.major = 2;
    expectCode("E_PLUGIN_ABI", delegate{ validatePlugin(&api); });
    api.major = 1;
    api.compilerVersion = compilerMajor + 1;
    expectCode("E_PLUGIN_ABI", delegate{ validatePlugin(&api); });
}

@("initialization preflights scaffold conflicts and preserves template specs")
unittest
{
    import rattpack.config.profiles;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    auto root = buildPath(fixture.root, "starter");
    mkdirRecurse(root);
    atomicWrite(buildPath(root, "README.md"), "keep me");
    expectCode("E_SPEC", { initialize(root, "c-exe", fixture.config, true); });
    readText(buildPath(root, "README.md")).shouldEqual("keep me");
    assert(!exists(buildPath(root, "Rattspec")));
    assert(!exists(buildPath(root, "src")));
    remove(buildPath(root, "README.md"));
    atomicWrite(buildPath(root, "Rattspec.in"), "keep template");
    expectCode("E_SPEC", { initialize(root, "empty", fixture.config); });
    assert(!exists(buildPath(root, "Rattspec")));
}

@("shipped scaffolds produce valid graphs and escape project names")
unittest
{
    import rattpack.config.profiles;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    foreach (profile; [
        "c-exe", "c-lib", "cxx-exe", "cxx-lib", "d-exe", "d-lib", "empty",
        "monorepo"
    ])
    {
        auto root = buildPath(fixture.root, profile ~ " project");
        initialize(root, profile, fixture.config, true);
        auto graph = new SpecLoader(root, fixture.config).load;
        assert(graph.actions.length);
        assert(exists(buildPath(root, "Rattpkg")));
        assert(exists(buildPath(root, "README.md")));
    }
    auto root = buildPath(fixture.root, "quoted\"project");
    initialize(root, "empty", fixture.config, true);
    new SpecLoader(root, fixture.config).load.projectName.shouldEqual("quoted\"project");
}

private class QueueProbe : Scheduler
{
    import core.sync.mutex : Mutex;
    import core.sync.condition : Condition;
    import core.thread : Thread;

    Mutex mutex;
    Condition changed;
    Thread coordinator;
    size_t active, peak;
    bool bStarted, cStarted;
    bool handshake;
    bool failed;
    string[] visited;

    this(Graph graph, Configuration config, size_t jobs, bool handshake = false)
    {
        super(graph, config, jobs);
        this.handshake = handshake;
        mutex = new Mutex;
        changed = new Condition(mutex);
        coordinator = Thread.getThis;
    }

    override void executeAction(Action action, void delegate(string) log = null)
    {
        import core.time : seconds;

        assert(Thread.getThis !is coordinator, "actions must execute on worker system threads");
        synchronized (mutex)
        {
            active++;
            if (active > peak)
                peak = active;
            visited ~= action.name;
            if (action.serial)
                assert(active == 1);
        }
        scope (exit)
            synchronized (mutex)
            {
                active--;
                changed.notifyAll;
            }
        synchronized (mutex)
        {
            if (failed && action.name == "a")
                fail("E_ACTION", "intentional worker failure");
            if (handshake)
            {
                if (action.name == "b")
                    bStarted = true;
                if (action.name == "c")
                    cStarted = true;
                changed.notifyAll;
                while ((action.name == "a" && !bStarted) || (action.name == "b" && !cStarted))
                    if (!changed.wait(3.seconds))
                        fail("E_ACTION", "worker queue did not release a ready dependent action");
            }
        }
        atomicWrite(buildPath(graph.root, action.outputs[0]), action.name);
    }
}

private Graph probeGraph(string root)
{
    auto graph = new Graph(root);
    foreach (name; ["a", "b", "c", "serial"])
    {
        auto action = new Action;
        action.name = name;
        action.outputs = ["build/" ~ name];
        if (name == "c")
            action.dependencies = ["a"];
        if (name == "serial")
            action.serial = true;
        graph.add(action);
    }
    return graph;
}

@("system thread queue obeys jobs and releases dependents without a batch barrier")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    auto parallel = new QueueProbe(probeGraph(fixture.root), fixture.config, 2, true);
    parallel.build.executed.shouldEqual(4);
    parallel.peak.shouldEqual(2);
    parallel.jobs.shouldEqual(2);
    parallel.build.skipped.shouldEqual(4);
    auto single = new QueueProbe(probeGraph(buildPath(fixture.root, "single")), fixture.config, 1);
    single.build.executed.shouldEqual(4);
    single.peak.shouldEqual(1);
}

@("worker failures stop dependent actions and join the pool")
unittest
{
    import std.algorithm : canFind;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    auto scheduler = new QueueProbe(probeGraph(fixture.root), fixture.config, 2);
    scheduler.failed = true;
    expectCode("E_ACTION", { scheduler.build; });
    scheduler.active.shouldEqual(0);
    assert(!scheduler.visited.canFind("c"));
}

@("hermetic actions reject undeclared reads and changes to frozen inputs")
unittest
{
    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("input", "declared");
    fixture.put("secret", "undeclared");
    fixture.put("Rattspec", "project(name: \"strict\", version: \"1\", kind: \"single\")\n"
            ~ "import \"fs\"\nlet t = rule(name: \"t\", inputs: [\"input\"], output: \"build/t\")\n"
            ~ "action(t) { fs.write(\"build/t\", fs.read(\"secret\")) }\n");
    auto graph = new SpecLoader(fixture.root, fixture.config).load;
    auto scheduler = new Scheduler(graph, fixture.config, 2);
    scheduler.hermetic = true;
    expectCode("E_HERMETIC", { scheduler.build; });
    fixture.put("Rattspec", readText(buildPath(fixture.root, "Rattspec"))
            .replace("fs.read(\"secret\")", "fs.read(\"input\")"));
    graph = new SpecLoader(fixture.root, fixture.config).load;
    scheduler = new Scheduler(graph, fixture.config, 2);
    scheduler.hermetic = true;
    scheduler.build.executed.shouldEqual(1);
    scheduler.build.skipped.shouldEqual(1);
    fixture.put("input", "changed");
    expectCode("E_HERMETIC", { scheduler.build; });
}

@("assist proposals are decoded, validated, and applied atomically")
unittest
{
    import rattpack.spec.assist;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    // An existing spec is input only; the proposal below creates just the manifest.
    fixture.put("Rattspec",
            "project(name: \"app\", version: \"1.0.0\", kind: \"single\")\n"
            ~ "rule(name: \"r\", output: \"build/r\")\n");
    auto project = readAssistProject(fixture.root);
    project.files["Rattspec"].present.shouldBeTrue;
    // Build the response with the JSON writer; a Rattscript file contains real
    // newlines that cannot be embedded in a hand-written JSON string literal.
    string proposal(string name, string contents)
    {
        auto files = jsonObject();
        files[name] = JSONValue(contents);
        auto response = jsonObject();
        response["files"] = files;
        response["summary"] = JSONValue("done");
        return response.toString;
    }

    auto manifest = "package(name: \"app\", version: \"1.0.0\")\ndeps {\n"
        ~ "  dep \"fmt\" from: git(\"https://example.org/fmt.git\"), tag: \"11.0.2\"\n}\n";
    // Unpinned Git dependencies are rejected by the real manifest reader.
    expectCode("E_ASSIST", delegate{
        decodeAssistProposal(proposal("Rattpkg", "package(name: \"app\", version: \"1.0.0\")\n"
            ~ "deps { dep \"fmt\" from: git(\"https://example.org/fmt.git\") }\n"), project);
    });
    expectCode("E_ASSIST", delegate{
        decodeAssistProposal(proposal("README.md", "text"), project);
    });
    expectCode("E_ASSIST", delegate{
        decodeAssistProposal(proposal("Rattpkg", "package(name: \"app\", version: 1)\n"), project);
    });
    expectCode("E_IDENTITY_MISMATCH", delegate{
        decodeAssistProposal(proposal("Rattspec",
            "module(name: \"sub\")\n" ~ "rule(name: \"r\", output: \"build/r\")\n"), project);
    });
    // A Rattspec without a target, or with two identities, is not a usable spec.
    expectCode("E_ASSIST", delegate{
        decodeAssistProposal(proposal("Rattspec",
            "project(name: \"app\", version: \"1.0.0\", kind: \"single\")\n"), project);
    });
    expectCode("E_ASSIST", delegate{
        decodeAssistProposal(proposal("Rattpkg",
            "package(name: \"app\", version: \"1.0.0\")\npackage(name: \"app\", version: \"1.0.0\")\n"),
            project);
    });
    // Fenced JSON from a chatty model is accepted.
    auto accepted = decodeAssistProposal("```json\n" ~ proposal("Rattpkg",
            manifest) ~ "\n```", project);
    accepted.files["Rattpkg"].shouldEqual(manifest);
    applyAssistProposal(project, accepted);
    readText(buildPath(fixture.root, "Rattpkg")).shouldEqual(manifest);
    // The untouched spec keeps its original content.
    readText(buildPath(fixture.root, "Rattspec")).startsWith("project(name: \"app\"").shouldBeTrue;
    // A concurrent edit during generation aborts without touching either file.
    fixture.put("Rattpkg", "package(name: \"other\", version: \"2\")\n");
    expectCode("E_ASSIST", delegate{ applyAssistProposal(project, accepted); });
    readText(buildPath(fixture.root, "Rattpkg")).shouldEqual(
            "package(name: \"other\", version: \"2\")\n");
}

@("directory maps scan, serialise, memory-map and render terse text")
unittest
{
    import rattpack.dirmap;
    import rattpack.rt.map : mapFile;
    import std.string : splitLines;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    fixture.put("src/main.c", "int main(void) { return 0; }\n");
    fixture.put("src/core/util.h", "int f(void);\n");
    fixture.put("README.md", "# demo\n");
    mkdirRecurse(buildPath(fixture.root, ".git"));
    atomicWrite(buildPath(fixture.root, ".git/config"), "ignored");
    mkdirRecurse(buildPath(fixture.root, "build"));
    atomicWrite(buildPath(fixture.root, "build/out.o"), "generated");
    atomicWrite(buildPath(fixture.root, "src/main.c"), "int main(void) { return 1; }\n");

    auto scanned = scanDirectory(fixture.root);
    // Version control metadata and build output are never mapped.
    string rendered = renderDirMap(scanned);
    assert(!rendered.canFind(".git"), rendered);
    assert(!rendered.canFind("out.o"), rendered);
    // The root is node zero, children follow in preorder, and indentation
    // carries depth without any end markers.
    scanned.nodes[0].kind.shouldEqual(DirKind.directory);
    scanned.nodes[0].depth.shouldEqual(0u);
    assert(scanned.nodes.canFind!(n => n.name == "util.h"));
    assert(rendered.splitLines.length == scanned.nodes.length);

    auto path = buildPath(fixture.root, "map.bin");
    writeDirMap(path, scanned);
    auto mapped = MappedDirMap.open(path);
    scope (exit)
        mapped.close;
    mapped.live.shouldBeTrue;
    mapped.length.shouldEqual(scanned.nodes.length);
    foreach (index, node; scanned.nodes)
    {
        auto round = mapped.node(index);
        round.name.shouldEqual(node.name);
        round.kind.shouldEqual(node.kind);
        round.depth.shouldEqual(node.depth);
        round.size.shouldEqual(node.size);
        round.contentId.shouldEqual(node.contentId);
        round.fileCount.shouldEqual(node.fileCount);
    }
    // Text from the mapping must be identical to text from the scan.
    renderMappedDirMap(mapped).shouldEqual(rendered);
    // Directory totals cover the whole subtree.
    scanned.nodes[0].fileCount.shouldEqual(3u);
    // Names containing the attribute separator are escaped in the text form.
    auto odd = new Fixture;
    scope (exit)
        odd.close;
    odd.put("a b:c.c", "x\n");
    renderDirMap(scanDirectory(odd.root)).canFind("a\\ b\\:c.c").shouldBeTrue;
    // A map that is not a map is rejected rather than misread.
    expectCode("E_MAP", {
        atomicWrite(buildPath(fixture.root, "bogus.bin"), "not a map at all, really");
        MappedDirMap.open(buildPath(fixture.root, "bogus.bin"));
    });
    expectCode("E_MAP", { mapFile(buildPath(fixture.root, "absent.bin")); });
}

@("Rattpack.json resolves flags, environment, and configuration in order")
unittest
{
    import rattpack.config.tool;
    import std.process : environment;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    // A missing file yields defaults rather than an error.
    loadToolConfig(buildPath(fixture.root, "empty")).backend
        .shouldEqual(AssistBackend.opencode);
    fixture.put("rattpack/Rattpack.json",
            "{\"backend\":\"openai\","
            ~ "\"openai\":{\"base_url\":\"http://localhost:8080/v1\","
            ~ "\"api_key\":\"from-file\",\"model\":\"file-model\","
            ~ "\"api\":\"responses\",\"timeout\":45},"
            ~ "\"opencode\":{\"executable\":\"oc\",\"standalone\":false},"
            ~ "\"map\":{\"summary\":false,\"max_entries\":5000},"
            ~ "\"plugins\":{\"openai-assist\":\"p.so\"},"
            ~ "\"scripts\":{\"scaffold\":\"s.ratt\"},"
            ~ "\"commands\":{\"format\":\"clang-format\"}}");
    auto config = loadToolConfig(buildPath(fixture.root, "rattpack"));
    config.backend.shouldEqual(AssistBackend.openai);
    config.openai.baseUrl.shouldEqual("http://localhost:8080/v1");
    config.openai.api.shouldEqual("responses");
    config.openai.timeout.shouldEqual(45u);
    config.opencode.executable.shouldEqual("oc");
    config.opencode.standalone.shouldBeFalse;
    config.map.summary.shouldBeFalse;
    config.map.maxEntries.shouldEqual(5000u);
    config.plugins["openai-assist"].shouldEqual("p.so");
    config.scripts["scaffold"].shouldEqual("s.ratt");
    config.commands["format"].shouldEqual("clang-format");

    // A flag wins, the environment beats the file, and a default loses.
    resolveSetting("flag", ["RATTPACK_UNIT_MISSING"], "file", "fallback")
        .shouldEqual("flag");
    environment["RATTPACK_UNIT_SETTING"] = "env";
    scope (exit)
        environment.remove("RATTPACK_UNIT_SETTING");
    resolveSetting("", ["RATTPACK_UNIT_SETTING"], "file", "fallback")
        .shouldEqual("env");
    resolveSetting("", ["RATTPACK_UNIT_MISSING"], "file", "fallback")
        .shouldEqual("file");
    resolveSetting("", ["RATTPACK_UNIT_MISSING"], "", "fallback")
        .shouldEqual("fallback");
    // An unparsable timeout must not silently disable the deadline.
    resolveTimeout("", ["RATTPACK_UNIT_MISSING"], 90).shouldEqual(90u);
    resolveTimeout("0", [], 90).shouldEqual(90u);
    resolveTimeout("30", [], 90).shouldEqual(30u);
    // Malformed configuration is a diagnostic.
    fixture.put("bad/Rattpack.json", "{ not json");
    expectCode("E_CONFIG", { loadToolConfig(buildPath(fixture.root, "bad")); });
    fixture.put("bad/Rattpack.json", "{\"backend\": \"anthropic\"}");
    expectCode("E_CONFIG", { loadToolConfig(buildPath(fixture.root, "bad")); });
}

@("action environment is explicit, frozen, hashed and round trips")
unittest
{
    import std.process : environment;

    auto fixture = new Fixture;
    scope (exit)
        fixture.close;
    environment["RATTPACK_UNIT_AMBIENT"] = "ambient";
    scope (exit)
        environment.remove("RATTPACK_UNIT_AMBIENT");
    fixture.put("Rattspec", "project(name: \"env\", version: \"1\", kind: \"single\")\n" ~ "import \"fs\"\nimport \"proc\"\nlet t = rule(name: \"t\", output: \"build/t\", env: {DECLARED: \"frozen\"})\n" ~ "action(t) { fs.write(\"build/t\", proc.env(\"DECLARED\") + proc.env(\"RATTPACK_UNIT_AMBIENT\", \"absent\")) }\n");
    auto graph = new SpecLoader(fixture.root, fixture.config).load;
    auto restored = Graph.importGraph(graph.toDot);
    restored.digest.shouldEqual(graph.digest);
    auto scheduler = new Scheduler(restored, fixture.config, 2);
    scheduler.hermetic = true;
    scheduler.build;
    readText(buildPath(fixture.root, "build/t")).shouldEqual("frozenabsent");
    auto before = graph.actions["t"].id;
    graph.actions["t"].environment["DECLARED"] = "changed";
    graph.finalize;
    assert(graph.actions["t"].id != before);
}
