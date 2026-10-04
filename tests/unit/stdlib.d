module tests.stdlib;

import unit_threaded;
import rattpack.config.environment : Configuration;
import rattpack.diagnostic : Diagnostic, Location;
import rattpack.script.evaluator : DeferredAction, Environment, Evaluator, Phase;
import rattpack.script.lint : lintFile;
import rattpack.script.snapshot : freeze, thaw;
import rattpack.script.value : Value;
import rattpack.stdlib.modules : installStdlib;
import std.path : buildPath;

private Evaluator interpreter(Phase phase = Phase.construction)
{
    auto evaluator = new Evaluator(phase);
    installStdlib(evaluator, new Configuration(cast(Value[string]) null));
    return evaluator;
}

@("stdlib source modules lint, import once, and keep native helpers private")
unittest
{
    auto evaluator = interpreter;
    foreach (name; [
        "collections", "list", "dict", "sets", "iter", "functional", "math",
        "stats", "json", "regex", "base64", "semver"
    ])
    {
        lintFile(buildPath("stdlib", name ~ ".ratt"));
        auto first = evaluator.importModule(name, Location.init);
        auto second = evaluator.importModule(name, Location.init);
        assert(first.data.mapValue is second.data.mapValue);
        assert(("_native" in first.data.mapValue.values) is null);
    }
    evaluator.run(`import "str"; import "semver"; assert(semver.bump("1.2.3") == "1.2.4")`);
    auto independent = interpreter;
    auto first = evaluator.importModule("math", Location.init);
    first.data.mapValue.values["pi"] = Value(0);
    assert(independent.importModule("math", Location.init).data.mapValue.values["pi"].number > 3);
}

@("stdlib callbacks and native primitives survive deterministic action snapshots")
unittest
{
    auto construction = interpreter;
    DeferredAction deferred;
    construction.actionHandler = (action) { deferred = action; };
    construction.run(`
import "functional"
import "list"
import "dict"
import "sets"
import "iter"
import "math"
import "stats"
import "json"
import "regex"
import "base64"
import "semver"
let scale = functional.compose(math.sqrt, fn(n) { return n * n * 4 })
action {
    print(json.stringify({values: list.sort([10, 2]), scaled: scale(3), release: semver.bump("1.2.3")}))
    print(regex.find(base64.decode(base64.encode("v12")), "[0-9]+"), stats.mean([2, 4]))
    print(dict.get({x: 42}, "x"), sets.is_subset([1], [1, 2]), iter.scan([1, 2], 0, fn(a, b) { return a + b }))
}`);
    auto snapshot = freeze(deferred);
    freeze(deferred).shouldEqual(snapshot);
    // No source-module imports are needed in the fresh execution evaluator.
    auto execution = interpreter(Phase.execution);
    string output;
    execution.output = (line) { output ~= line ~ "\n"; };
    auto restored = thaw(execution, snapshot);
    execution.execute(restored.body, new Environment(restored.closure));
    output.shouldEqual(
            "{\"release\":\"1.2.4\",\"scaled\":6.0,\"values\":[2,10]}\n"
            ~ "[12] 3\n42 true [0, 1, 3]\n");
}

@("stdlib rejects malformed data and invalid numeric domains with runtime diagnostics")
unittest
{
    foreach (source; [
        `import "json"; json.parse("9223372036854775808")`,
        `import "json"; json.parse("1e999")`,
        `import "json"; json.parse("true false")`,
        `import "json"; json.parse("NaN")`,
        `import "json"; json.stringify(float("nan"))`,
        `import "json"; let value = {}; value.self = value; json.stringify(value)`,
        `import "base64"; base64.decode("Zg")`,
        `import "base64"; base64.decode("Zg===")`,
        `import "base64"; base64.decode("Zg==\n")`,
        `import "base64"; base64.decode("!g==")`,
        `import "base64"; base64.decode("Pz8/", url_safe: true)`,
        `import "regex"; regex.find("x", "[")`, `import "math"; math.log(0)`,
        `import "math"; math.exp(10000)`, `import "math"; math.sqrt(float("nan"))`,
        `import "math"; math.pow(2, 63)`, `import "math"; math.pow(0, -1)`,
        `import "math"; math.clamp(0, 10, 1)`,
        `import "math"; math.abs(-9223372036854775808)`,
        `import "stats"; stats.mean([])`, `import "stats"; stats.quantile([1], 2)`,
        `import "iter"; iter.take([1], -1)`,
        `import "functional"; functional.repeat(fn(x) { return x }, -1)`,
        `import "semver"; semver.bump("9223372036854775807.0.0", "major")`,
        `import "semver"; semver.bump("1.2.3", "build")`,
        `import "semver"; semver.sort(["invalid"])`
    ])
    {
        try
        {
            interpreter.run(source);
            assert(false, "expected E_RUNTIME for " ~ source);
        }
        catch (Diagnostic diagnostic)
        {
            diagnostic.code.shouldEqual("E_RUNTIME");
        }
    }
}

@("stdlib source signatures preserve type and arity diagnostics")
unittest
{
    foreach (source; [
        `import "json"; json.parse(1)`, `import "json"; json.stringify(set([1]))`,
        `import "json"; json.stringify(fn(x) { return x })`,
        `import "regex"; regex.test("x", "x", flags: 1)`,
        `import "base64"; base64.encode("x", url_safe: "yes")`,
        `import "list"; list.flatten([[1], 2])`,
        `import "list"; list.slice([1], stop: "bad")`,
        `import "dict"; dict.from_items([[1, 2]])`,
        `import "sets"; sets.union([1], 2)`,
        `import "functional"; functional.pipe([1])`,
        `import "stats"; stats.sum([1, "bad"])`, `import "math"; math.pow("x", 1)`
    ])
    {
        try
        {
            interpreter.run(source);
            assert(false, "expected E_TYPE for " ~ source);
        }
        catch (Diagnostic diagnostic)
        {
            diagnostic.code.shouldEqual("E_TYPE");
        }
    }
    foreach (source; [
        `import "list"; list.chunks([1])`,
        `import "json"; json.parse("{}", unknown: true)`,
        `import "math"; math.sqrt(1, value: 2)`
    ])
    {
        try
        {
            interpreter.run(source);
            assert(false, "expected E_ARITY for " ~ source);
        }
        catch (Diagnostic diagnostic)
        {
            diagnostic.code.shouldEqual("E_ARITY");
        }
    }
}

@("JSON nesting limits permit boundary round trips and reject deeper containers")
unittest
{
    auto evaluator = interpreter;
    evaluator.run(`
import "json"
let nested = 0
for i in range(256) { nested = [nested] }
let encoded = json.stringify(nested)
assert(json.stringify(json.parse(encoded)) == encoded)
assert(len(encoded) == 513)
`);
    foreach (source; [
        `json.stringify([nested])`, `json.parse("[" + encoded + "]")`,
        `let empty = []; for i in range(256) { empty = [empty] }; json.stringify(empty)`
    ])
    {
        try
        {
            evaluator.run(source);
            assert(false, "expected E_RUNTIME for " ~ source);
        }
        catch (Diagnostic diagnostic)
        {
            diagnostic.code.shouldEqual("E_RUNTIME");
        }
    }
}

@("SemVer implements the specification's complete prerelease precedence example")
unittest
{
    interpreter.run(`
import "semver"
let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
    "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
for left in range(len(ordered)) {
    for right in range(len(ordered)) {
        let comparison = semver.compare(ordered[left], ordered[right])
        assert((left < right and comparison == -1) or (left > right and comparison == 1) or
            (left == right and comparison == 0))
    }
}
assert(semver.compare("1.0.0-1", "1.0.0--") == -1)
assert(semver.compare("1.0.0+1", "1.0.0+2") == 0)
assert(semver.sort(["1.0.0+2", "1.0.0+1"]) == ["1.0.0+2", "1.0.0+1"])
`);
}
