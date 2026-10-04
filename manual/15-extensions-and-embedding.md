# 15. Extensions, plugins, and embedding

[Previous: Exporters](14-exporters.md) · [Contents](README.md) · [Next: Portability and automation](16-portability-and-automation.md)

## 15.1 Choose an extension surface

Use an ordinary `.ratt` source module when the feature can be expressed in
Rattscript. This keeps extensions portable and allows the normal evaluator,
phase checks, and closure serialization to apply.

Native D plugins are appropriate for capabilities needing native libraries,
new host services, or an exporter implemented in D. They use Rattpack's
versioned D ABI and compatible shared runtime.

Programmatic embedding is a third option: a D application can link the runtime,
install context-specific modules, evaluate scripts, load graphs, or call package
management APIs directly.

## 15.2 A reusable Rattscript declaration helper

Save this as `tools/generated.ratt`:

```ratt
import "fs"

fn text_file(name: str, destination: str, contents: str) -> rule {
  let output = rule(name: name, output: destination)
  action(output) { fs.write(destination, contents) }
  return output
}
```

In the root `Rattspec`:

```ratt
project(name: "helpers", version: "1.0.0", kind: "single")
import "./tools/generated.ratt" as generated
let greeting = generated.text_file("greeting", "build/greeting.txt", "hello\n")
```

The helper's `rule` binding is supplied by the build-spec host. The action
captures the helper's parameters, so the text is deferred rather than written
during construction. The module must be used in a build context; evaluating
that declaration helper with an unconfigured standalone host does not install
the target machinery automatically.

Helper modules should accept context-sensitive paths and settings as arguments.
Their imports are relative to their source files, while filesystem paths still
use the calling evaluator's working directory.

## 15.3 Native ABI definition

The authoritative declaration is
[`source/rattpack/plugin/abi.d`](../source/rattpack/plugin/abi.d).
Its V1 layout is:

```d
struct RattPluginV1
{
    uint structSize;
    uint major;
    uint minor;
    string compiler;
    uint compilerVersion;
    PluginKind kind;
    string name;
    extern(D) int function(string dagJSON, string destination,
                          string host, out string error) exportGraph;
    extern(D) int function(string url, string destination,
                          out string error) fetchPackage;
    extern(D) string function(string language) discoverToolchain;
    extern(D) void function(Evaluator evaluator) registerModules;
}
```

This listing shows field order; use the imported type's actual default
initializers in your code. They supply structure size, ABI major `1`, minor `0`,
compiler-family identity, and the header's compiler-major calculation. A freshly
zeroed hand-written imitation is not equivalent to `RattPluginV1.init`.

`PluginKind` is a `uint` enum with `exporter`, `fetcher`, `toolchain`, and
`stdlib` values in that order. Callbacks use `extern(D)`, not a C callback ABI.
D strings, delegates, class references, exceptions, and GC-managed objects make
compatible runtime linkage essential.

## 15.4 Entry point

The shared library must export a symbol named exactly
`rattpack_plugin_entry`, returning a pointer to a live `RattPluginV1`.

This complete plugin reuses the shipped Ninja exporter callback:

```d
module example_exporter;

import rattpack.plugin.abi;
import rattpack.plugin.exporters : exportNinja;

private RattPluginV1 plugin;

pragma(mangle, "rattpack_plugin_entry")
export extern(D) RattPluginV1* rattpack_plugin_entry()
{
    plugin = RattPluginV1.init;
    plugin.kind = PluginKind.exporter;
    plugin.name = "example-ninja";
    plugin.exportGraph = &exportNinja;
    return &plugin;
}
```

The static variable outlives the entry call. Do not return a pointer to a stack
variable. The unmangled symbol name is stable while the function call convention
remains D.

## 15.5 Capability callbacks

### Exporter

`exportGraph` receives canonical graph JSON, an output directory, and the host
executable path. It should validate/deserialize the DAG, write its build
description, and return zero on success. On failure, set `error` and return a
nonzero status. The build CLI wraps callback failure as `E_GRAPH`.

Use `Graph.fromJSON(parseJSON(dagJSON))` to validate identity consistency. Consume
the supplied graph only; never load or reevaluate a `Rattspec` inside the
exporter. If emitting frozen-action invocations, preserve working-directory,
input/output, dependency, and captured-runtime semantics.

### Fetcher

`fetchPackage` receives a source URL and destination directory and has the same
integer-status/error-string result convention. The ABI defines this extension
point, but the shipped `rattpkg` CLI does not expose a plugin-source selection
option. An embedding host must deliberately connect the callback to its own
fetching workflow and integrity checks.

### Toolchain

`discoverToolchain` returns a compiler command string for a language. As with
fetchers, there is no shipped CLI flag registering an arbitrary toolchain
plugin. An embedding host can invoke it and feed the result into its chosen
configuration/declaration workflow.

### Standard library

`registerModules` receives an evaluator to extend. Bind native functions with
`Evaluator.bind` or populate a module map with `Evaluator.native` and register
it in `evaluator.modules`. Mark side-effecting functions effectful:

```d
evaluator.bind("host_write", (args, location) {
    // Perform the host's write operation here.
    return Value.init;
}, true);
```

The final `true` allows `Evaluator.invoke` to enforce construction-phase checks,
including calls through aliases or helpers. A native operation's write-root
checks are a separate responsibility: effect marking alone does not prove its
filesystem writes remain in action output directories.

The shipped CLIs do not automatically discover/load native stdlib plugins.
An embedding host installs them explicitly. If custom native names are captured
in deferred snapshots, the execution host must register compatible names when
thawing them; the standard frozen runner preloads the shipped native modules.

## 15.6 Building plugins

For the repository's four first-party plugins:

```sh
DC=ldc2 python3 tools/dogfood.py plugins
```

or with the POSIX convenience wrapper:

```sh
DC=ldc2 sh tools/build-plugins.sh
```

The helper obtains the package import/string-import paths from DUB's JSON
description, compiles each `plugins/<exporter>/plugin.d`, and writes shared
libraries under `build/plugins/`. It links against the repository's shared
`librattpack` and a shared D runtime. Plugin runtime search paths refer to the
parent `build/` directory on POSIX/macOS.

For a custom plugin, use the helper's compiler invocation as a template. The
required pieces are:

- Source import paths for Rattpack and the D dependencies referenced by headers.
- String-import paths for embedded resources where the imported headers require
  them.
- `-preview=dip1000` and the compiler's shared-library/PIC options.
- Linkage to the matching Rattpack shared implementation/import library.
- Shared D runtime linkage, not a second statically linked runtime.
- A runtime library-search layout compatible with the host deployment.

LDC uses `-link-defaultlib-shared`; the Linux DMD bootstrap uses
`-defaultlib=libphobos2.so`. The helper chooses platform/compiler options; do not
apply Linux loader flags unchanged to Windows or macOS.

## 15.7 Loading and lifetime

The build CLI loads exporter libraries passed as existing `--to` paths. It
locates the entry symbol and validates:

- A non-null vtable pointer and sufficient structure size.
- ABI major compatibility.
- Compiler-family and header compiler-major fields.
- A nonempty plugin name.
- The callback required by the declared kind.

An incompatible library or missing callback raises `E_PLUGIN_ABI`. The version
field uses the `compilerMajor` definition in `abi.d` (`__VERSION__ / 1000`);
using a consistent compiler/toolchain build is still the practical compatibility
rule rather than treating the check as proof of every possible binary match.

For an embedding application:

```d
auto plugin = new Plugin(pluginPath);
scope (exit) plugin.close();
// Invoke the selected callback while plugin is still loaded.
```

Import `rattpack.plugin.loader` for `Plugin`. Keep the library loaded while its
vtable, callback code, registered native functions, or plugin-owned data can be
referenced. `close` invalidates the plugin's exposed API pointer; it is not a
safe way to unload code still used by an evaluator.

## 15.8 Embedding the interpreter

A minimal standalone evaluator setup in D:

```d
import rattpack.script.evaluator;
import rattpack.stdlib.modules;
import std.stdio : writeln;

void evaluateExample(string directory)
{
    auto evaluator = new Evaluator(Phase.standalone, directory);
    installStdlib(evaluator);
    evaluator.output = (line) { writeln(line); };
    evaluator.run(`print(6 * 7)`, "<embedded>");
}
```

The evaluator constructor installs language built-ins. `installStdlib` supplies
module loading and template preprocessing, using the supplied configuration or
the default user config. A source label ending in `.in` enables preprocessing
through the installed transform. Set an output callback when messages should
be visible.

The embedded collection/codec/math libraries use the normal snapshot path.
`installStdlib` eagerly registers their native primitives before a saved action
is thawed; source-module helpers and composed callbacks are restored from the
captured object graph. [Chapter 24](24-writing-rattscript-libraries.md) explains
how to build reusable modules and extend the embedded library registry.

Use `Phase.construction` when a host is collecting deterministic declarations.
Install its target functions and action handler explicitly, or use the existing
specification loader. Use `Phase.execution` with appropriate write roots and
process runner when executing captured work. The scheduler provides that setup
for normal builds.

## 15.9 Embedding build and package operations

The principal D APIs are:

| API | Operation |
| --- | --- |
| `Configuration(directory, warningsAsErrors, sink)` | Load config and defaults |
| `SpecLoader(root, configuration, warningsAsErrors, sink).load()` | Evaluate specs and return a finalized graph |
| `Scheduler(graph, configuration, jobs).build(targetNames)` | Execute a selected prerequisite closure |
| `Graph.importGraph(serializedText)` | Import canonical JSON or Rattpack DOT payload |
| `graph.toJSON`, `graph.toDot`, `graph.digest` | Serialize/identify a graph |
| `PackageManager(root, configuration).resolve(update)` | Resolve and write a lockfile |
| `manager.fetch(lock)` / `manager.verify(lock)` | Acquire/check locked package trees |
| `readLock(path)` / `writeLock(path, lock)` | TOML lockfile access |

Import their modules from `rattpack.config`, `rattpack.spec`, `rattpack.graph`,
and `rattpack.pkg` as shown in the source tree. `Scheduler.output` and
`PackageManager.output` are optional log callbacks. Package branch opt-in is
the manager's `allowFloating` field.

Public graph classes expose fields for advanced hosts, but the serialized
format and ABI are not interchangeable: a plugin exporter receives JSON to
validate, not an arbitrary pointer to a host graph's mutable internals.

## 15.10 ABI evolution

Vtable evolution is append-only. Never reorder or remove fields. Append new
fields and increment the ABI minor version according to the repository
contract; incompatible redesigns require an appropriate major-version design.
New plugins must still supply compatible defaults and the capability callback.

Read [`AGENTS.md`](../AGENTS.md) before changing runtime/ABI code. Native platform
changes belong in the backend directories, and trusted D operations need their
ownership/bounds justification documented in source.
