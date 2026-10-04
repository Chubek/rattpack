# 18. Development and implementation guide

[Previous: Diagnostics](17-diagnostics.md) · [Contents](README.md) · [Next: Recipes](19-recipes.md)

This chapter is for contributors and integrators working on the implementation.
[`AGENTS.md`](../AGENTS.md) is the repository contract; consult it before changing
source behavior, dependency pins, platform interfaces, or the plugin ABI.

## 18.1 Repository map

| Path | Responsibility |
| --- | --- |
| `source/apps/` | Thin `main` entry points for the three applications |
| `source/rattpack/cli/` | Command parsing and command orchestration |
| `source/rattpack/script/` | Lexer, parser, AST, values, environments, evaluator, lint, snapshots |
| `source/rattpack/stdlib/` | Module registry and native math/codec/regex primitives |
| `stdlib/` | Embedded Rattscript algorithms and public wrappers for native primitives |
| `source/rattpack/spec/` | Identity/discovery and target lowering |
| `source/rattpack/graph/` | Artifact/action model, hashes, scheduling, cache |
| `source/rattpack/config/` | TOML/YAML settings, profiles, template rendering |
| `profiles/` | Embedded shipped `.in` initialization templates |
| `source/rattpack/pkg/` | Manifest, resolution/acquisition, extraction, lockfiles |
| `source/rattpack/plugin/` | ABI, loader, built-in exporter callbacks |
| `plugins/` | First-party shared-library exporter entry points |
| `source/rattpack/rt/` | Common services and Win32/macOS/POSIX backends |
| `source/rattpack/native/` | D native bindings and the C ownership bridge |
| `third_party/` | Pinned native Git submodules |
| `runtime/dub.sdl` | Shared implementation's DUB description |
| `dub.sdl` | Applications, tests, bootstrap-runtime, quality configurations |
| `tools/` | Native build, dogfood, plugin, and quality helpers |
| `tests/unit/` | D tests using unit-threaded |
| `tests/script/` | Rattscript golden fixtures |
| `tests/integration/` | End-to-end fixtures, compiler/export/package harness |
| `docs/`, `manual/` | Quick references and this manual |

## 18.2 Bootstrap and self-hosting

```sh
dub build -c rattbuild --compiler=ldc2
./build/rattbuild build --warnings-as-errors
./build/rattbuild build --warnings-as-errors
```

The root `Rattspec` builds the shared runtime and then the application entry
points. A subsequent unchanged run should skip the four declared targets.
This checks both the host bootstrap and its own input/recipe tracking.

The runtime's native pre-build command calls `tools/build-native.py`, which uses
the CMake project in `tools/native/`. The native archives are position-independent
and linked into the D shared runtime. The helper builds a copy of zlib's source
under the build tree because its configure process modifies a source header;
the pinned submodule worktree is preserved.

`tools/dogfood.py library` preserves the active host's loaded runtime inode while
DUB publishes a replacement. Application helpers compile to temporary output
names before replacement. These details matter because the software is
rebuilding binaries/libraries that the invoking host is currently using.

The helper uses the root `bootstrap-runtime` configuration to retain root-level
dependency selections. Compiler import and string-import flags come from DUB's
JSON description rather than guessed package paths.

## 18.3 D compiler/runtime constraints

Source builds use `-preview=dip1000`. Public D APIs should remain `@safe` where
possible. Every `@trusted` region needs a `// TRUSTED:` justification describing
the relevant ownership, lifetime, bounds, or foreign-interface guarantee.

The host, application entry points, and plugins link a shared D runtime. Mixing
independent statically linked runtimes in the same process is not the supported
plugin model. Keep compiler families and compatible header/runtime builds
consistent.

For DMD self-hosting, set `toolchain.d = "dmd"`; setting only DUB's bootstrap
compiler does not change graph discovery. Use a separate checkout/output set
when validating DMD and LDC concurrently so one compiler does not replace the
other's host runtime.

## 18.4 Unit tests

```sh
dub test --compiler=ldc2
```

The D suite covers language semantics, linting, phase enforcement, snapshots,
configuration/templates, graph identities, scheduling/tamper checks,
monorepo identity, lockfile round-tripping, and ABI validation. Test fixtures
use isolated directories and remove them after execution.

`tests/unit/stdlib.d` additionally covers embedded-module loading and isolation,
annotation linting, malformed inputs, numeric domains, JSON nesting boundaries,
SemVer precedence, and deterministic action restoration with native helpers.

Use `--compiler=dmd` for compatibility checks. Test the affected subsystem and
the required suite after source changes. Meaningful tests should verify a
behavioral boundary rather than merely repeat the implementation's operations.

## 18.5 Rattscript golden tests

```sh
dub build -c rattsc --compiler=ldc2
./build/rattsc --test tests/script
```

Each fixture has a `.ratt` source and sibling `.expected` file. The runner
captures output as text and compares exact bytes, including line endings and
final newlines. A caught `Diagnostic` appends its code to that output.

The repository additionally recognizes fixture prefixes:

| Prefix | Evaluation path |
| --- | --- |
| No special prefix | Standalone script |
| `# phase: construction` | Construction-phase evaluator |
| `# lint` | Static AST annotation lint path |
| `# test: spec` / `build` | Isolated spec-loading/build scenario |
| `# test: identity` / `nested` | Isolated subordinate/nested identity scenario |
| `# test: manifest` / `floating` | Manifest or floating-dependency scenario |
| `# test: config` / `dual-config` | Configuration loader scenario |
| `# test: template` | Render the remaining template text |
| `# test: graph` | Import graph-format scenario |
| `# test: plugin` | Plugin loader failure scenario |
| `# test: cli` | Invalid public command scenario |

These prefixes must begin the file as expected by the runner. They are fixture
metadata, not a different user-language syntax. The command's `--lint FILE`
path also follows imported files and preprocesses `.in` sources, while the
golden `# lint` fixture path directly checks its parsed AST.

Every new coded diagnostic needs documentation and a golden case according to
the repository contract.

The `stdlib-*.ratt` fixtures exercise the expanded modules in construction mode,
along with codec/domain failures and callback phase enforcement. See
[chapter 24](24-writing-rattscript-libraries.md) for a small complete golden suite.

## 18.6 Integration tests

```sh
./tests/integration/run.sh
```

The shell launcher builds all applications with `${DC:-ldc2}`, builds matching
first-party plugins, and starts the Python harness. The harness uses real C,
C++, and D compilers and all four external build systems. It creates isolated
projects/config/cache directories and loopback HTTP/FTP servers.

Covered workflows include native incrementality and tampered outputs,
captured closures, DOT round trips, source/header templates, frozen exported
configuration, dynamic exporter loading, profiles, monorepos, member lockfile
lookup, Git pins, registry backtracking, archive formats, executable metadata,
and cache verification.

Changes under graph, package, or plugin code require the integration suite.
Ensure the required tools are on `PATH`. The Python harness expects Python 3.11+
and uses subprocess timeouts so a stuck external tool fails the scenario.

## 18.7 Formatting and style checks

```sh
sh tools/check.sh
```

This helper uses the pinned formatter and scanner, then runs unit/golden tests.
It formats `source/`, `tests/unit/`, and `plugins/` in place. Use `DC` to select
its compiler.

Individual checks:

```sh
dub run dfmt@0.15.2 --compiler=ldc2 -- -i source/ tests/unit/ plugins/
dub run dscanner@0.16.0-beta.5 --compiler=ldc2 -- --styleCheck source/
```

Style settings are in `.editorconfig` and `dscanner.ini`. Formatting modifies
source files, so review the resulting changes before committing.

## 18.8 Dependency policy

D dependency versions are exact selections in `dub.selections.json`. The root
`Rattpkg` mirrors direct and transitive runtime/test/quality dependencies with
pinned Git tags or revisions. Native libraries are pinned by submodule commit.

The native libraries are BLAKE3, libgit2, zlib, and xz. D dependencies provide
TOML/YAML parsing, transport, semantic versions, MessagePack, value/container
support, CLI parsing, terminal facilities, and development tools.

When adding a D dependency, update the dependency table in `AGENTS.md` and the
root `Rattpkg`. Pin changes require a changelog entry. Do not mix package-update
work into unrelated changes without accounting for the resulting reproducibility
changes. Review submodule worktree cleanliness after native build changes.

## 18.9 Interpreter pipeline

The lexer produces tokens with source locations. The parser produces statement
and expression trees. The evaluator executes those nodes directly using nested
environments and dynamically tagged values. There is no bytecode compiler stage.

Native calls carry a name and effectful flag. Invocation checks the phase before
calling an effectful operation. User functions retain their defining environment;
list/map/set storage is reference-oriented so aliases and closures can observe
shared mutations.

Source-module ASTs and evaluated modules are cached within an evaluator. A new
CLI invocation creates a new evaluator; this is distinct from the on-disk action
execution cache. Performance changes should work within the tree-walking/caching
model rather than replace it with a compiler without the required design process.

## 18.10 Snapshot pipeline

The snapshot layer serializes deferred action bodies and environment/value
graphs. It records shared object identity so repeated references to the same
collection or closure remain shared after thawing. Native bindings are restored
by registered names; bound list methods preserve their receivers.

The scheduler restores captured settings and sets up a fresh execution evaluator
with declared file scopes and the captured process environment. `installStdlib`
eagerly registers the embedded libraries' native primitives; the scheduler also
loads the core native modules before thawing the action and executing its body
in a child environment. Custom embedding hosts must arrange compatible
registration for their own captured native bindings.

## 18.11 Graph and package internals

Graph finalization validates input files and walks prerequisite order to compute
content-based identities. Canonical JSON has sorted object keys; graph arrays
are assembled in deterministic name/path order. DOT carries that JSON as its
round-trip payload.

The scheduler uses MessagePack cache entries keyed by action name, with recipe/
input keys and output hashes. Ready actions run on a bounded system-thread pool;
completion releases dependent work without a batch barrier. The coordinator
collects each action's logs and records successful output hashes.

Package resolution uses deterministic name ordering and descending semantic
versions with backtracking. Acquired candidates are memoized within a manager
instance and published into content-addressed cache paths. Lockfiles are atomic,
sorted TOML. Byte checksums and tree hashes are SHA-256; graph hashing is BLAKE3.

## 18.12 Contribution boundaries

- Preserve construction purity and sorted discovery.
- Keep exporters consumers of the DAG, without spec reevaluation.
- Preserve JSON/DOT identity round trips.
- Correct identity files rather than weakening mismatch validation.
- Put platform-specific source under `rt/<backend>/`.
- Keep plugin ABI fields append-only and version additions correctly.
- Document diagnostics and add their required golden cases.
- Treat unfamiliar working-tree changes as potentially belonging to another
  contributor.

Commit summaries use `component: imperative summary`, for example
`graph: hash toolchain fingerprint into node id`. If implementation and the
repository contract disagree, record a `spec-drift:` issue with the discrepancy
rather than silently redefining the contract.

## 18.13 Embedded standard-library implementation

The current library has two cooperating layers:

- [`source/rattpack/stdlib/modules.d`](../source/rattpack/stdlib/modules.d)
  selects built-in names, preprocesses template sources, and evaluates embedded
  `.ratt` modules in their own scopes.
- [`source/rattpack/stdlib/primitives.d`](../source/rattpack/stdlib/primitives.d)
  registers portable native math, JSON, regex, and Base64 primitives. Stable
  names such as `json.stringify` allow snapshot restoration.

`runtime/dub.sdl` exposes `stdlib/` as a string-import directory. The module
registry embeds each registered source with D's `import("name.ratt")`; the root
dogfood spec tracks `stdlib/*.ratt` as runtime inputs. Adding a source file also
requires registering its import name and rebuilding the shared runtime.

Embedded modules export their own top-level bindings. For modules using native
support, an extra parent scope supplies `_native` without exporting it in the
module map. Each evaluator caches the resulting module, keeping initialization
and mutable module state isolated from other evaluators.

Pure collection algorithms belong in Rattscript. Native support handles library
operations such as strict JSON parsing or floating-point functions, with the
usual typed-value conversion and phase checks. Registration happens before
thawing so execution does not depend on a fresh source import occurring first.
[Chapter 24](24-writing-rattscript-libraries.md) turns this architecture into a
contribution workflow.
