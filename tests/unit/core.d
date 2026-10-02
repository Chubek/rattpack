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
import std.file;
import std.path;
import std.random : uniform;
import std.conv : to;
import std.json;

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
