# 1. Overview and core concepts

[Contents](README.md) · [Next: Installation](02-installation.md)

## 1.1 What Rattpack does

Rattpack combines a build system with a source-package manager. Projects describe
their builds in **Rattscript**, a dynamically typed language whose evaluator
walks a syntax tree directly. A build description is an executable program:
functions, loops, conditionals, collections, and imported helpers can all be
used to declare a project's work.

The result of evaluating a build description is a **directed acyclic graph**
(DAG). Its artifacts are source or generated files; its actions describe the
commands or deferred Rattscript needed to produce outputs. Rattpack can execute
that graph itself or export it to another build system.

Package resolution is a separate operation. The package manager obtains and
verifies dependency source trees, then records their exact identities in a
lockfile. Build evaluation can read those dependencies without performing
package resolution or downloading them.

## 1.2 The four components

| Component | Responsibility | Typical invocation |
| --- | --- | --- |
| `rattbuild` | Load specifications, create the graph, build, clean, or export | `rattbuild build` |
| `rattpkg` | Resolve dependencies, populate the package cache, verify content | `rattpkg resolve` |
| `rattsc` | Execute standalone scripts, run a REPL, lint annotations, run golden tests | `rattsc tools/check.ratt` |
| `librattpack` | Shared implementation used by applications and native plugins | Loaded by the applications |

The applications are small entry points into the shared library. Native plugins
also use that library and the compatible shared D runtime. Keep these components
together when deploying a build from source.

## 1.3 The project lifecycle

A typical application follows this sequence:

1. Create a root `Rattspec` describing the project and at least one target.
2. Add a `Rattpkg` if the project consumes managed dependencies.
3. Run `rattpkg resolve` to choose and fetch dependencies and create `Rattpkg.lock`.
4. Run `rattpkg verify` when checking the package cache's integrity.
5. Run `rattbuild build` to evaluate the specification and execute required work.
6. Repeat the build after changes; content checks decide which actions to rerun.
7. Optionally export the evaluated graph with `rattbuild export --to=ninja` or
   another exporter.

Projects without managed dependencies can begin at step 5. A raw Git or archive
dependency need not itself contain a Rattpack build description.

## 1.4 Construction and execution are different phases

The most important distinction in Rattpack is **when a piece of Rattscript runs**.

### Construction

Construction evaluates the specification tree and declares the graph. It can
perform read-only queries such as sorted file discovery, configuration lookup,
and compiler discovery. It cannot call effectful standard-library operations
such as `fs.write`, `proc.run`, or `proc.env`.

```ratt
project(name: "example", version: "1.0.0", kind: "single")
import "fs"

let input_files = fs.glob("data/**/*.txt")
let generated = rule(name: "generated", output: "build/report.txt",
                     inputs: input_files)
```

Here `fs.glob` executes while the graph is constructed. The rule records work;
it has not yet created `build/report.txt`.

### Execution

An `action` block supplies deferred work for a target:

```ratt
action(generated) {
  fs.write("build/report.txt", "ready\n")
}
```

This body executes only when the scheduler decides the action needs rebuilding.
Its lexical environment and configuration are serialized during construction.
Exported builds use those captured values too.

A forbidden construction-phase effect raises `E_PHASE_VIOLATION`, even when the
effectful function is reached through an alias or helper function. Moving a call
into a helper does not change its phase.

Standalone `rattsc` execution is a third context: it permits effectful calls
directly, and an `action` statement runs its body immediately. Standalone scripts
do not automatically create build graphs.

## 1.5 Determinism and tracking

Rattpack uses BLAKE3 for graph identities and build file-content checks. An action
identity incorporates its recipe, input identities, dependencies, and toolchain
information. A native build cache also records output content. Editing an output
can therefore invalidate a native cache hit even if its timestamp looks current.

Deterministic construction and complete input tracking are complementary:

- Construction must describe the same graph for the same declared inputs and
  configuration.
- Files read by an execution-time action must be declared in its `inputs:`,
  `sources:`, `headers:`, or `raw_inputs:` fields as appropriate.
- Additional tools used inside an action need meaningful recipe or toolchain
  tracking if their changes should trigger rebuilding.

Reading a file with `fs.read` does not by itself register a graph dependency.
Compiler header searches do not automatically register headers either. Explicit
tracking is discussed in [chapter 8](08-actions-and-graphs.md).

## 1.6 File roles

| File | Role |
| --- | --- |
| `Rattspec` | Root build description with `project(...)` |
| `Rattspec.m` | Automatically discovered subordinate build description with `module(...)` |
| `Rattpkg` | Package identity and dependency declarations |
| `Rattpkg.lock` | Generated TOML selection of exact dependency content |
| `*.ratt` | Reusable or standalone Rattscript source |
| `*.in` | Input to the Rattscript template preprocessor |
| `Config.toml` / `Config.yaml` | User configuration, outside the project by default |

Build specifications can also use the template forms `Rattspec.in` and
`Rattspec.m.in`. Their identities and discovery rules remain the same.

## 1.7 Glossary

- **Artifact:** a graph file node, either an external input or an action output.
- **Action:** a named unit of execution with inputs, outputs, and prerequisites.
- **Target:** a user-facing declaration lowered to an action; compiled targets
  also provide compiler commands.
- **Rule:** a custom target whose execution is supplied explicitly.
- **Recipe:** the serialized execution description and settings contributing to
  an action's identity.
- **Toolchain fingerprint:** an identity derived from a tool's path, executable
  bytes, and version-query output.
- **Subordinate module:** part of one project's build identity, declared in a
  `Rattspec.m`; distinct from an imported Rattscript source module.
- **Monorepo member:** an explicitly listed nested project with its own identity.
- **Vendored member:** a nested project whose upstream project identity is
  preserved through an explicit monorepo declaration.
- **Frozen graph:** a serialized DAG containing commands, closures, and captured
  configuration, usable without reevaluating the original specs.
- **Profile:** a `.in` template used to generate an initial root `Rattspec`.
- **Package tree hash:** the SHA-256 identity of extracted or checked-out package
  paths, contents, and relevant entry metadata.

## 1.8 The expanded scripting toolbox

The runtime embeds reusable libraries alongside filesystem, process, path,
configuration, target, and package operations:

| Task | Modules | Walkthrough |
| --- | --- | --- |
| Shape lists/maps and combine callbacks | `collections`, `list`, `dict`, `sets`, `iter`, `functional` | [Chapter 20](20-collection-pipelines.md) |
| Read structured records and transform text | `json`, `regex`, `base64`, `str` | [Chapter 21](21-structured-data-and-text.md) |
| Compute numeric summaries | `math`, `stats` | [Chapter 22](22-numeric-analysis.md) |
| Validate and order release versions | `semver` | [Chapter 23](23-versioned-release-workflows.md) |

Import these modules by name. Their source files are compiled into the shared
runtime, so a deployed interpreter does not need a separate `stdlib/` directory.
Pure helpers work during construction and execution, and their callbacks retain
the calling phase's restrictions. Imported helpers can be captured in frozen
actions, including helpers that use the shipped native codec/math primitives.

Proceed to [installation](02-installation.md), or use the
[first-project tutorial](03-first-project.md) if the applications are available.
