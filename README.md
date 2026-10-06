# Rattpack

Rattpack is a portable build system and package manager implemented in D. Its
tree-walking **Rattscript** language describes projects, build actions, and
package dependencies. All four command-line applications share `librattpack`.

The [Rattpack Manual](manual/README.md) provides a complete, chapter-by-chapter
guide to installation, the language and APIs, building, packages, exporters,
extensions, and troubleshooting.

- **`rattbuild`** discovers specs, constructs a content-hashed artifact/action
  DAG, executes it incrementally and in parallel, and exports frozen graphs.
- **`rattpkg`** resolves registry and Git dependencies, downloads HTTP/FTP
  archives, writes deterministic TOML lockfiles, and verifies cached content.
- **`rattsc`** runs Rattscript, checks optional annotations, runs golden tests,
  and provides a REPL.
- **`rattspec`** creates and updates `Rattspec` and `Rattpkg` from a
  natural-language request through OpenCode or any OpenAI-compatible server,
  and maps directories into a terse inventory.
- **`ratt-language-server`** provides static editor diagnostics, completion,
  hover, definitions, and document symbols over LSP.

## Build and test

Prerequisites: DUB, LDC or DMD, a C compiler, CMake, OpenSSL development headers,
and Python 3 (3.11+ for integration tests). Native libraries
are pinned Git submodules; D packages are pinned in `dub.selections.json`.

```sh
git submodule update --init --recursive
dub build -c rattbuild --compiler=ldc2
./build/rattbuild build                 # build the shared runtime and all CLIs
dub test --compiler=ldc2
./build/rattsc --test tests/script
./tests/integration/run.sh              # also needs cmake, ninja, make, meson
sh tools/check.sh                       # pinned formatter, linter, unit/golden tests
```

Applications can also be bootstrapped separately with `dub build -c rattsc` or
`dub build -c rattpkg`; build editor services with
`dub build -c ratt-language-server`. Set `DC` to choose the compiler for
repository helpers.
The bootstrap library links the pinned BLAKE3, libgit2, zlib, and xz sources.
The self-hosted build uses the configured `toolchain.d`; set it to `dmd` when
dogfooding a DMD bootstrap. Plugins must use the same compiler as their host.

## A C project

Create a root `Rattspec`:

```ratt
project(name: "hello", version: "1.0.0", kind: "single")
import "fs"
import "target"

target.executable(
  name: "hello",
  language: "c",
  sources: fs.glob("src/**/*.c"),
  flags: ["-O2", "-Wall"]
)
```

```sh
rattbuild build -j 8
rattbuild build hello
rattbuild graph --dot -o graph.dot
rattbuild graph --import graph.dot --json
rattbuild build --dry-run
rattbuild clean
```

`-C DIRECTORY` selects a project directory. Languages are `c`, `cxx`, and `d`.
`target.library(...)` creates a static library; `shared: true` creates a shared
library. Pass target handles or names in `deps:` to order actions and link library
outputs. Additional inputs can be declared using `inputs:` and `headers:`.
For rules that embed template resources for later instantiation, `raw_inputs:`
tracks the original bytes without generating configured files.

## Custom actions

Construction is deterministic and side-effect-free. Actions capture lexical
scopes and are evaluated only when their outputs need rebuilding:

```ratt
project(name: "generated", version: "1.0.0", kind: "single")
import "fs"
import "proc"

let output = rule(name: "generated", inputs: ["input.txt"],
                  output: "build/generated.txt")
action(output) {
  fs.write("build/generated.txt", fs.read("input.txt"))
  proc.run(["echo", "generated"])
}
```

Rules also accept `command: ["program", "argument", ...]`. Failed commands and
missing outputs fail the build. Cache hits require matching input content,
recipe/toolchain identity, and output content, rather than timestamps alone.

Actions have a writable output-directory scope. POSIX uses Bubblewrap when
available and usable; macOS uses `sandbox-exec` when available. Win32 provides
action-scoped filesystem APIs and temporary directories. `sandbox: false` is an
explicit escape hatch for actions such as the repository's DUB bootstrap, which
needs to populate the compiler's dependency cache.

## Exporters and plugins

```sh
rattbuild export --to=cmake -o generated/cmake
rattbuild export --to=gnumake -o generated/make
rattbuild export --to=ninja -o generated/ninja
rattbuild export --to=meson -o generated/meson
sh tools/build-plugins.sh
rattbuild export --to=build/plugins/ninja.so -o generated/plugin
```

Exporters receive only the serialized DAG. They emit native build-system rules
that execute frozen actions through the host, including serialized Rattscript
closures. The original specs need not be present at execution time. Meson uses
stamp targets with content-checked action caches.

Native plugins export the D-ABI symbol `rattpack_plugin_entry`, returning the
append-only `RattPluginV1` vtable from `source/rattpack/plugin/abi.d`. Supported
kinds are exporter, fetcher, toolchain, and stdlib. A plugin must share the host's
D compiler family/major and shared runtime. See [plugin development](docs/plugins.md).

## Identity, modules, and monorepos

Subordinate modules use **both** a `Rattspec.m` filename and `module(name:)`.
Discovery is automatic; do not import subordinate specs explicitly. Module
targets are namespaced as `module::target`.

```ratt
project(name: "workspace", version: "1.0.0", kind: "monorepo")
monorepo {
  member "libs/first"
  vendored "third_party/second"
  ignore "third_party/unused"
}
```

Members keep their project identities, output scopes, and `project::target`
namespaces. Undeclared nested projects emit `W_UNDECLARED_NESTED_SPEC`, share
identity/resources, and are serialized. Use `--warnings-as-errors` in CI.

## Configuration and initialization

Configuration lives in `$XDG_CONFIG_HOME/rattpack/Config.toml` (or
`%APPDATA%\rattpack\Config.toml` on Windows). YAML is accepted; TOML wins when both
exist and emits `W_DUAL_CONFIG`. Keys are available read-only as
`env.get("toolchain.c")`.

```sh
rattbuild --init --list-profiles
rattbuild --init --profile=cxx-exe
```

Shipped profiles: `c-exe`, `c-lib`, `cxx-exe`, `cxx-lib`, `d-exe`, `d-lib`,
`monorepo`, and `empty`. Add `.in` templates to the config directory's
`buildprof/`. Templates support `@{expression}`, `@if`/`@else`/`@end`, and
`@foreach item in values`/`@end`, with config values plus initialization variables
`cwd`, `dirname`, `user`, and `date`.

## Packages

```ratt
package(name: "app", version: "1.0.0", license: "MIT")
deps {
  dep "library" from: registry, version: "^1.0"
  dep "source" from: git("https://example.org/source.git"), tag: "v1.2.0"
  dep "archive" from: http("https://example.org/archive.tar.xz"),
      sha256: "<64 hexadecimal digits>"
}
```

```sh
rattpkg resolve                     # writes Rattpkg.lock and populates cache
rattpkg resolve --update            # explicitly refresh resolution
rattpkg fetch                       # immutable URLs/revisions from the lock
rattpkg verify                      # re-hash all cached package trees
```

Git remotes may have a `Rattpkg`, just a `Rattspec`, or neither. Git tags/revisions
are resolved to commits; branches require `--allow-floating` during resolution.
HTTP and FTP archives require SHA-256. Supported archives are tar, tar.gz,
tar.xz, and zip; extraction rejects traversal and archive link entries. Packages
are cached under `$XDG_CACHE_HOME/rattpack/pkgs/<name>/<tree-hash>/`.

Applications should commit `Rattpkg.lock`; libraries should not. `rattbuild` can
query already-fetched dependencies through `pkg.get("name")` and never fetches
them itself. See the [registry protocol](docs/registry.md).

## Assisted specification editing

`rattspec assist` writes `Rattspec` and `Rattpkg` from a natural-language request.
Select the backend explicitly, or set a default in `Rattpack.json`:

```sh
rattspec assist 'add these libraries: fmt and zlib' --opencode
rattspec assist 'build a C library and an exe that links it' --openai \
    --openai-url http://127.0.0.1:8000/v1 --openai-user builder --model my-model
rattspec assist 'turn this into a monorepo' --dry-run
```

`--opencode` goes through OpenCode V2's own CLI, so its discovery and
authentication apply. `--openai` reaches any OpenAI-compatible server via the
vendored openaipp client, with a bearer key or basic credentials.

Proposals are parsed, linted, and checked against the real manifest reader before
anything is written, and files edited during generation are never overwritten.
Model output is not executed.

## Directory maps

`rattspec map` records a directory as a compact binary map in
`.cache/rattpack/<directoryname>.bin`, which `assist` attaches to requests so a
large project is described by one short inventory. The text form is terse by
design:

```text
d demo:F6:B273.5k
 f README.md:7:b21109ab
 f run.sh:X:10:bc1f407a
 d src:F4:B273.5k
  f main.c:22:0b377551
```

```sh
rattspec map . --print
```

See the [command-line reference](manual/04-command-line.md) and
`man/rattspec.1`.

## Rattscript

```sh
rattsc program.ratt
rattsc --lint program.ratt
rattsc -e 'fn square(x: int) -> int { return x * x } print(square(7))'
rattsc                             # REPL; :q quits
```

Values: `nil`, bool, signed 64-bit int, float, string, path, list, map, set,
function, target, rule, and package. Functions are lexical closures. Statements
include `let`/`var`/`const`, assignment, `if`/`else`, `while`, `for ... in`,
`return`, `break`, `continue`, and `import`. Newlines and semicolons separate
statements. Named arguments use `name: value`. Annotations are checked by the
linter and when values cross annotated runtime bindings/parameters.
`--lint` also checks statically imported source modules, including `.in` modules,
without running their top-level statements.

Standard modules: `fs`, `path`, `proc`, `str`, `toolchain`, `target`, `pkg`, `env`,
`log`, `collections`, `list`, `dict`, `sets`, `iter`, `functional`, `math`,
`stats`, `json`, `regex`, `base64`, and `semver`. The Rattscript library sources
are embedded in the runtime. See the [language reference](docs/rattscript.md),
[standard-library manual](manual/06-standard-library.md), and
[diagnostics](docs/diagnostics.md).

## Editor integration

[`addons/`](addons/README.md) contains Vim, Neovim, and Sublime Text packages for
Rattscript, `Rattspec`/`Rattspec.m`, `Rattpkg`, and their templates. Neovim 0.8+
starts the bundled server through its native LSP client. Vim supports saved-file
linting and external LSP clients; Sublime Text integrates with the LSP package.

```sh
dub build -c ratt-language-server
python3 tests/addons/run.py
```

The installer includes the server and places editor packages under
`share/rattpack/addons/`. See the [add-on guide](addons/README.md) for setup and
configuration.
