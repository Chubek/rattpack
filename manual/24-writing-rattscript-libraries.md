# 24. Writing and maintaining Rattscript libraries

[Previous: Release workflows](23-versioned-release-workflows.md) · [Contents](README.md) · [Next: Hermetic builds](25-hermetic-builds.md)

A source module can serve standalone programs, build specifications, and deferred
actions. The expanded standard library supplies the collection, codec, and numeric
operations needed to keep most such helpers in portable Rattscript. This chapter
develops one small library, tests it, and explains the embedded-library path.

## 24.1 Extract a pure helper

Save as `tools/reports.ratt` in a project root:

```ratt
import "math"
import "stats"

fn summarize(values: list) -> map {
  assert(len(values) > 0, "at least one sample is required")
  let numbers = []
  for value in values {
    let number: float = value
    assert(math.is_finite(number), "samples must be finite")
    numbers.append(float(number))
  }
  return {count: len(numbers), mean_ms: stats.mean(numbers),
          median_ms: stats.median(numbers), p95_ms: stats.quantile(numbers, 0.95)}
}
```

The function accepts numeric values, creates its own result container, and has
no filesystem/process effects. Its imports are resolved in the module scope,
independent of the importing script's local bindings.

Save this independent caller as root `check-report.ratt`:

```ratt
import "./tools/reports.ratt" as reports

let result = reports.summarize([10, 20, 30])
assert(result.count == 3)
assert(result.mean_ms == 20 and result.median_ms == 20)
print(result.count, result.mean_ms, result.median_ms)
```

```sh
rattsc --lint check-report.ratt
rattsc check-report.ratt
```

The output is `3 20 20`. A path-bearing import selects the local source module;
`import "stats"` inside it selects an embedded standard module. Import paths are
relative to the importing file, while `fs` operations use the evaluator's working
directory. Pass context-sensitive paths as arguments to helpers that perform I/O.

## 24.2 Define an API contract

Useful contracts cover:

- Parameter kinds and named-argument spelling.
- Empty-input behavior and numeric domains.
- Whether a result is a fresh container and whether nested values are shared.
- Callback order and short-circuit behavior.
- Whether operations are pure or require execution/standalone context.

Annotations are checked by lint when inferable and at runtime when a value
crosses an annotated parameter, binding, or return. A `float` annotation accepts
an integer without converting it; explicit conversion in the helper above makes
floating-point accumulation intentional.

Top-level module bindings are exported, including imported module maps. There
is no private/export keyword. Prefixing an internal helper with `_` is a naming
convention, not access control. Keep examples focused on the supported public
functions and avoid unnecessary module-level mutable state.

Library contracts use the existing diagnostic codes: wrong kinds are `E_TYPE`,
signature mismatches are `E_ARITY`, and failed domain assertions are `E_RUNTIME`.
For new host-defined diagnostic codes, add the code documentation and golden
coverage required by [`AGENTS.md`](../AGENTS.md).

## 24.3 Call the same helper from an action

With the module above, create `data/samples.json`:

```json
{"samples_ms":[10,20,30]}
```

Complete root `Rattspec`:

```ratt
project(name: "shared-report", version: "1.0.0", kind: "single")
import "./tools/reports.ratt" as reports
import "fs"
import "json"

let report = rule(name: "report", output: "build/report.json",
                  inputs: ["data/samples.json"])
action(report) {
  let document = json.parse(fs.read("data/samples.json"))
  let result = reports.summarize(document.samples_ms)
  fs.write("build/report.json", json.stringify(result, pretty: true) + "\n")
}
```

```sh
rattsc --lint Rattspec
rattbuild build report
```

The data file is read at execution and declared as an input. The helper's code
and its imported standard-library functions are captured in the action snapshot.
Editing the helper changes the recipe when the spec is reconstructed; an old
frozen graph continues to use its captured helper body until recaptured.

Collection identities and function closures survive snapshot restoration.
Mutating a captured collection is local to that action's thawed environment;
it is not a communication mechanism between separately scheduled actions.
Use generated files and dependencies for producer/consumer communication.

## 24.4 Preserve phase boundaries through callbacks

`functional.compose`, `functional.pipe`, and `collections` helpers do not grant
special execution permissions to callbacks. A callback eventually reaching a
native write/process operation is checked by the invoking evaluator.

For example, this is an intentionally failing golden test of construction:

```ratt
# phase: construction
import "functional"
import "iter"
import "proc"

let callback = functional.compose(fn(value) { return value }, proc.env)
iter.any(["HOME"], callback)
```

When run by the golden runner, it produces `E_PHASE_VIOLATION`. The first-line
header selects construction mode for that runner; ordinary `rattsc FILE` uses
standalone mode and treats the header as a comment. Defer the callback invocation
to an action when reading execution-time process values is the intended behavior.

## 24.5 Add a small golden suite

Create `tests/script/reports.ratt` in the same project:

```ratt
# phase: construction
import "../../tools/reports.ratt" as reports
let result = reports.summarize([10, 20, 30])
print(result.count, result.mean_ms, result.median_ms)
```

Sibling `tests/script/reports.expected`:

```text
3 20 20
```

Create `tests/script/reports-empty.ratt`:

```ratt
import "../../tools/reports.ratt" as reports
reports.summarize([])
```

Sibling `tests/script/reports-empty.expected`:

```text
E_RUNTIME
```

Each expected file must include a final newline. Run:

```sh
rattsc --lint tools/reports.ratt
rattsc --test tests/script
```

These cases verify an independently known result and the empty-input contract.
Additional useful boundaries include wrong element kinds, native domains,
shared-reference behavior, callback phases, and freeze/thaw restoration. D unit
tests are appropriate for host registration and snapshot boundaries; the
repository's examples are in [`tests/unit/stdlib.d`](../tests/unit/stdlib.d).

## 24.6 Contribute an embedded standard module

An ordinary local extension needs only its `.ratt` file. A library shipped as
`import "name"` needs build-time embedding and registration:

1. Add `stdlib/name.ratt` with the public Rattscript API.
2. Add its name to `embeddedSource` in
   [`source/rattpack/stdlib/modules.d`](../source/rattpack/stdlib/modules.d).
3. When native support is necessary, register stable `name.method` primitives
   in [`source/rattpack/stdlib/primitives.d`](../source/rattpack/stdlib/primitives.d).
4. Add meaningful golden/unit coverage and update the API reference and manual.
5. Rebuild the runtime and run the required suites from chapter 18.

`runtime/dub.sdl` already includes `stdlib/` as a string-import directory, and the
root dogfood spec tracks its `.ratt` sources. The registry evaluates each embedded
source in a fresh module scope, then caches the resulting module per evaluator.

Modules such as `json` receive an internal `_native` map in a parent scope.
Their public wrappers validate source-level signatures, while native helpers
perform host conversions and library calls. `_native` is not exported from the
module map. Import these modules by their registered names; loading their source
files directly by path does not arrange that internal parent binding.

## 24.7 Restore native bindings before frozen execution

`installStdlib` eagerly registers native primitives even before their source
modules are imported. Snapshot restoration looks up native functions by those
stable names; it restores user-function bodies and scopes from the snapshot.
An execution host can therefore call a captured `stats` or `json` helper without
loading a fresh source module first.

Custom embedding hosts must install matching native bindings before thawing.
Side-effecting native callbacks must retain their effectful flag so phase checks
still apply through user wrappers. Keep public D interfaces `@safe` where
possible and justify any `@trusted` boundary as required by the repository
contract. Dependency and platform-code policies remain those in chapter 18.

Continue to [chapter 25](25-hermetic-builds.md) to give the report's execution
explicit input, output, environment, and tool contracts.
