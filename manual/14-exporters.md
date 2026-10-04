# 14. Exporting to other build systems

[Previous: Registries and archives](13-registries-and-archives.md) · [Contents](README.md) · [Next: Extensions and embedding](15-extensions-and-embedding.md)

## 14.1 The export model

An exporter consumes an already constructed DAG. It does not parse or reevaluate
Rattscript specs. The first-party exporters write native build-system rules
that call the recorded `rattbuild` host's frozen-action runner.

The generated project therefore needs a compatible Rattpack installation at
execution time. Export does not translate every Rattscript body into CMake/Make/
Ninja/Meson language or create a host-independent compiler project.

Each export directory contains `rattgraph.json` and the native build description.
The graph includes commands, serialized action closures, captured config values,
artifact identities, dependencies, and absolute context paths.

## 14.2 Exporter selection

```sh
rattbuild export --to=cmake -o generated/cmake
rattbuild export --to=gnumake -o generated/make
rattbuild export --to=ninja -o generated/ninja
rattbuild export --to=meson -o generated/meson
```

`make` is an alias for `gnumake`. Without `-o`, the destination is
`<project-root>/build/export/<exporter>`. Export uses the complete graph.
Target-name selection is not an export filtering interface.

The built-in exporters do not require separately compiled plugin files. A
native library path can select a dynamic exporter instead:

```sh
rattbuild export --to=/absolute/path/ninja.so -o generated/plugin
```

Use the platform's actual plugin suffix and a matching compiler/runtime.

## 14.3 CMake

The exporter writes `CMakeLists.txt` requiring CMake 3.20. Its project enables
no compiler language because compilation is performed by frozen custom actions.

```sh
rattbuild export --to=cmake -o generated/cmake
cmake -S generated/cmake -B generated/cmake/build
cmake --build generated/cmake/build -j 8
```

For each action it emits a custom command with the original output paths,
the graph file and input files as dependencies, and a custom target built by
default. Native prerequisites also receive target-level dependency links.

Generated target labels have the form `ratt_<action-id-prefix>`, not the original
Rattscript target name. Inspect `CMakeLists.txt` or the build-tool target listing
if a particular generated CMake target is needed. Regenerating the graph can
change those labels.

The resulting artifacts remain at their original declared project output paths.
The CMake build directory contains CMake's own bookkeeping, not a relocated copy
of the Rattpack project.

## 14.4 GNU Make

```sh
rattbuild export --to=gnumake -o generated/make
make -C generated/make -j 8
```

The exporter writes `Makefile`. Its default `all` target depends on all graph
outputs. Recipes call the frozen action runner, and outputs depend on the graph
JSON plus action inputs/prerequisite outputs. `.DELETE_ON_ERROR` is enabled.

For imported/programmatic graphs with multiple outputs per action, the exporter
uses GNU Make's grouped-target `&:` syntax, requiring GNU Make 4.3 or newer.
Ordinary Rattscript target declarations expose one output, but using a current
GNU Make version accommodates both forms.

Select specific output-file targets using the paths in the generated Makefile;
there are no automatically generated friendly aliases for all Rattscript names.

## 14.5 Ninja

```sh
rattbuild export --to=ninja -o generated/ninja
ninja -C generated/ninja -j 8
```

The generated `build.ninja` declares Ninja 1.10 as its required version. Each
action has a generated rule label and output edge. Inputs and prerequisite
outputs are listed, the graph JSON is an implicit dependency, and `restat = 1`
is set. `all` is the default phony target.

Ninja displays the original action name as the action description. Its output
targets use original artifact paths, so a selected output may be passed using
the spelling shown in `build.ninja`.

## 14.6 Meson

```sh
rattbuild export --to=meson -o generated/meson
meson setup generated/meson/build generated/meson
meson compile -C generated/meson/build -j 8
```

The exporter writes `meson.build`, requiring Meson 0.60 or newer. Each action
becomes a custom target producing a generated stamp filename in Meson's build
directory. Actual outputs still go to their declared Rattpack project paths.

The custom targets are `build_always_stale: true`. Meson invokes the host on
each build, and the host's per-action content cache decides whether real work
is required. Prerequisite custom targets establish action order.

These cache entries live under:

```text
<graph-cache-directory>/export/<BLAKE3-of-action-name>.msgpack
```

The action runner checks its frozen recipe identity, current input bytes, and
declared output bytes. A current action can skip actual work while the runner
still refreshes its Meson stamp.

## 14.7 Freshness differences

| Executor | What normally decides whether to invoke an action |
| --- | --- |
| Native `rattbuild build` | Recipe/input identity and output-content verification |
| Exported CMake | Native build tool's custom-command dependency/timestamp logic |
| Exported GNU Make | Make's dependency/timestamp logic |
| Exported Ninja | Ninja's dependency/timestamp logic, with graph-file dependency and `restat` |
| Exported Meson | Always invokes runner; runner uses Rattpack content checks |

The CMake/Make/Ninja runners execute an action when their outer build system
requests it; those exporters do not request the incremental-action cache used
by Meson. Consequently, editing an output while leaving it newer than all
inputs need not trigger the same content-based repair as a native build.

Native serial scheduling flags are not translated into equivalent global
serialization constructs in these exported build descriptions. External
schedulers follow emitted dependencies and their own concurrency rules. Model
shared resources with dependencies and correct project identities rather than
relying on the native undeclared-project fallback.

## 14.8 Frozen configuration and source captures

Exported action execution uses captured configuration. It can execute without
the original specs and without rereading their user config for action settings.
An edited or even malformed current config file does not replace values stored
inside a frozen action.

The expanded embedded libraries can be used by captured actions without a
separate runtime source installation. Helpers and composed callbacks are restored
from their serialized scopes, and the host registers their native primitives.
Graphs exported with `--hermetic` also preserve strict action flags, input/tool
hashes, and captured process environments. See [chapter 25](25-hermetic-builds.md)
for a complete frozen-report workflow and backend support.

Source reads differ by when they occur:

```ratt
let text_at_construction = fs.read("input.txt")
let result = rule(name: "result", output: "build/result.txt", inputs: ["input.txt"])
action(result) { fs.write("build/result.txt", text_at_construction) }
```

The body above uses captured text. Updating `input.txt` without reconstructing
the graph leaves that captured value unchanged, even if the native build system
reruns the action. By contrast:

```ratt
action(result) { fs.write("build/result.txt", fs.read("input.txt")) }
```

reads current text at execution. Choose the timing deliberately and re-export
when construction-time information should change.

## 14.9 When to re-export

Regenerate exports after changes to:

- Targets, commands, output locations, or dependency relationships.
- Imported helper code used in captured actions.
- Config settings or selected toolchain identity.
- The discovered source list, such as adding/removing files matched by a glob.
- Template text that was rendered into a configuration-action snapshot.
- File content read and captured during graph construction.

Execution-time inputs read through an unchanged recipe can change without
changing graph topology, but outer timestamp-based build tools still apply
their own invocation rules.

After re-exporting CMake or Meson descriptions, run their configure/setup
workflow as needed. Do not assume an old generated target label remains stable
across changed action identities.

## 14.10 Paths and deployment

The export stores the host executable path, graph root, action working
directories, inputs, and output paths. Moving the export directory alone is
not a way to relocate the source checkout. Keep the referenced source tree,
Rattpack shared library/runtime, and tools available at the captured locations,
or reconstruct/export a graph for the new locations.

`-C` selects a source root; an explicit relative `-o` is resolved from the
invoking shell directory. This is convenient for collecting several exports
outside their projects, but does not change artifact output roots.

For manually importing a graph, use the lossless JSON/DOT operations from
[chapter 8](08-actions-and-graphs.md). For writing your own exporter, continue
with [chapter 15](15-extensions-and-embedding.md).
