# 7. Projects, targets, and native compilation

[Previous: Standard library](06-standard-library.md) · [Contents](README.md) · [Next: Actions and graphs](08-actions-and-graphs.md)

## 7.1 Declare the project first

A root `Rattspec` starts by declaring the project's name, version, and kind:

```ratt
project(name: "application", version: "1.0.0", kind: "single")
```

The supported kinds are `single`, `multi-module`, and `monorepo`. Every root
spec, including a monorepo root, must declare at least one target in that spec.
Declare identity before targets. A file cannot make multiple identity
declarations, and subordinate files use `module` instead of `project`.

Project kind affects discovery and identity handling; it does not turn off
recursive discovery. A project marked `single` can still reveal a mistakenly
nested `Rattspec`, producing the undeclared-nested-project warning.

## 7.2 Declaration forms

```ratt
import "target"

let executable = target.executable(name: "app", language: "c",
                                   sources: ["src/main.c"])
let library = target.library(name: "codec", language: "c",
                             sources: ["src/codec.c"])
let generated = target.rule(name: "generated", output: "build/generated.txt")
```

The first two forms normally generate compiler commands. A rule needs a
`command:` or a deferred `action` block. The global `rule(...)` is equivalent to
the module's rule declaration.

The global `target(name: ..., kind: "executable", ...)` is also available before
the `target` module is imported. Importing `target` places a module map in the
current scope; use its explicit `executable`, `library`, and `rule` members.

Target names must be nonempty and must not contain path separators. Names must
be unique in their fully qualified namespace, and one output path may have only
one producer.

## 7.3 Target field reference

Use named fields for declarations, especially custom rules.

| Field | Type | Default / use |
| --- | --- | --- |
| `name` | `str` | Required target name |
| `language` | `str` | `"c"`; native compilation accepts `c`, `cxx`, `d` |
| `sources` | List of strings/paths | Empty; compilation units and tracked inputs |
| `output` | String/path | One output file; generated from name/kind when omitted |
| `inputs` | List of strings/paths | Extra tracked files, without treating them as compilation units |
| `headers` | List of strings/paths | Extra tracked files, normally headers |
| `raw_inputs` | List of strings/paths | Tracked original bytes; `.in` files are not automatically configured |
| `deps` | List of handles/names | Named prerequisites; their output files are also tracked |
| `compiler` | String/path | Per-target compiler override; otherwise `toolchain.<language>` |
| `flags` | List of strings/paths | Compiler arguments before source files |
| `include_dirs` | List of strings/paths | Paths converted to compiler `-I` arguments |
| `link_flags` | List of strings/paths | Additional linker arguments |
| `shared` | Bool | `false`; library declarations normally produce static libraries |
| `command` | List of strings/paths | Explicit argv command, overriding automatic compilation |
| `toolchain` | String | Additional explicit toolchain identity for custom work |
| `tools` | List of strings/paths | Additional programs resolved and content-hashed during construction, including tools called by deferred `proc.run` |
| `env` | Map of string/path values | Process-environment overrides captured into the action recipe |
| `sandbox` | Bool | `true`; action write scope and available subprocess restrictions |

The fields `inputs` and `headers` have the same tracking role; their separate
names help communicate intent. `include_dirs` specifies search locations but
does not register the contents of those directories as inputs.

`env:` extends the backend's deterministic default process environment. Its
values contribute to action identity and are supplied to sandboxed execution.
Recorded command executables and automatic compiler tools are tracked by the
loader; list additional action-body programs in `tools:`. Strict tool and file
access is demonstrated in [chapter 25](25-hermetic-builds.md).

Only one `output` is exposed by the Rattscript declaration interface. An action
can create ancillary files under its writable directories, but they are not
independently tracked outputs unless declared by suitable separate rules.

## 7.4 Default outputs and handles

Default executable output is `build/<name><executable-suffix>`. Default library
output is `build/lib<name><static-or-shared-suffix>`. The `lib` prefix is applied
by the declaration logic even on Windows. Set `output:` explicitly when a
different convention is required.

| Kind | POSIX | macOS | Windows |
| --- | --- | --- | --- |
| Executable `app` | `build/app` | `build/app` | `build/app.exe` |
| Static library `codec` | `build/libcodec.a` | `build/libcodec.a` | `build/libcodec.lib` |
| Shared library `codec` | `build/libcodec.so` | `build/libcodec.dylib` | `build/libcodec.dll` |

Paths in fields are resolved from the declaring spec's directory, then
normalized into graph paths. Target handles expose their declaration fields
through members such as `.name` and `.output`. `.name` is qualified; `.output`
is the graph-relative output path. In a subordinate/member spec, this may differ
from a path relative to that spec's execution directory. Use known context-local
paths inside its action or obtain an absolute graph path through your own
declaration convention.

Changing a handle's field map after declaration is not an output-relocation
interface. Define the desired output in the declaration itself.

## 7.5 C and C++ executables

Save as a complete `Rattspec` in a project containing the named sources:

```ratt
project(name: "native", version: "1.0.0", kind: "single")
import "fs"
import "target"

target.executable(
  name: "native",
  language: "cxx",
  sources: fs.glob("src/**/*.cpp"),
  headers: fs.glob("include/**/*.hpp"),
  include_dirs: ["include"],
  flags: ["-std=c++17", "-Wall", "-O2"],
  link_flags: []
)
```

The automatic C/C++ executable command has this general shape:

```text
compiler FLAGS -IINCLUDE ... SOURCES ... DEPENDENT_LIBRARIES ... LINK_FLAGS ... -o OUTPUT
```

All sources in the target are passed in a single compiler invocation. There is
no per-source incremental object graph for an executable declaration. Changing
one tracked header or source reruns that target's complete action.

Language `cxx` selects `toolchain.cxx`. Source filename extensions alone do not
select the configured language.

## 7.6 Static and shared libraries

```ratt
let codec = target.library(
  name: "codec",
  language: "c",
  sources: ["src/codec.c"],
  headers: ["include/codec.h"],
  include_dirs: ["include"],
  flags: ["-O2"]
)

target.executable(
  name: "app",
  language: "c",
  sources: ["src/main.c"],
  headers: ["include/codec.h"],
  include_dirs: ["include"],
  deps: [codec]
)
```

A C/C++ static-library action compiles each source to an object beside the
library output and then runs the discovered `ar` tool with `rcs`. These object
commands are sequential parts of one action; the scheduler counts the whole
library as one unit. The archiver fingerprint contributes to the toolchain
identity.

`shared: true` makes the automatic C/C++ library command use `-shared -fPIC` and
the shared-library suffix. It does not configure an install name, runtime search
path, import-library policy, or deployment layout automatically. Supply
appropriate `flags`/`link_flags` and deployment steps for your environment.

The static archiving branch creates a library from its own source objects.
`deps:` still orders prerequisites, but is not a mechanism for merging another
archive into the new archive. Likewise, library declarations do not propagate
include directories or usage requirements to consumers: declare the consumer's
header inputs, include directories, and necessary link flags explicitly.

## 7.7 D targets

```ratt
target.executable(name: "d-app", language: "d",
                  sources: ["source/main.d"],
                  flags: ["-preview=dip1000", "-g"])
```

The automatic D command passes flags, source files, dependent library outputs,
and link flags to the configured D compiler, then adds `-of=<output>`.
Static D libraries add `-lib`; shared D libraries add `-shared -fPIC`.

The compiler can be overridden per target:

```ratt
target.executable(name: "d-app", language: "d", compiler: "dmd",
                  sources: ["source/main.d"])
```

Imported D source files are not discovered by parsing import statements. Add
them to tracked fields and provide the compiler's import flags as needed. The
repository's own runtime bootstrap uses DUB/custom rules for its dependencies
and shared-runtime linkage; ordinary D target declarations do not implicitly
run DUB.

## 7.8 Dependencies by handle or name

```ratt
deps: [codec]
```

is generally preferable to repeating a target name. Strings are also accepted:

```ratt
deps: ["codec"]
```

Within a namespace, a bare dependency name resolves in that namespace. A name
containing `::` is treated as qualified. For example, a root executable can
depend on `"math::library"` declared in a member project.

Each named dependency contributes ordering and its output path as an input.
When the producer is a library and the consumer is automatically compiled,
that output is included among library arguments. A rule output is a prerequisite
but is not automatically a source compilation unit or linker argument. To use
a generated `.c` file, list it in `sources:` as well.

## 7.9 Toolchain identity and custom compilation

Automatic compilation locates the configured tool and fingerprints its path,
bytes, and `--version` output. A missing tool or empty compiled source list raises
`E_TARGET` before execution.

An explicit `command:` supplies one argv command. A declared deferred action
also replaces automatic compilation when no explicit command is present. This
allows alternative compilers or finer-grained object graphs:

```ratt
let object = rule(name: "object", output: "build/main.o",
                  inputs: ["src/main.c"],
                  command: ["cc", "-c", "src/main.c", "-o", "build/main.o"])
rule(name: "app", output: "build/app", deps: [object],
     command: ["cc", "build/main.o", "-o", "build/app"])
```

For custom work, include the true source/header inputs and a useful explicit
`toolchain:` identity. Command-first tools are queried for fingerprinting when
located; wrappers should handle `--version` predictably. Multi-command custom
work belongs in an action block using `proc.run`.
