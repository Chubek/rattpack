# GUIDE — Rattpack

A task-oriented tour of Rattpack: build descriptions, builds, packages,
and tooling. See `INSTALL.md` for setup and `manual/` for the complete
reference (chapter map in `manual/README.md`).

## 1. Concepts (read this first)

- **Rattscript** is a dynamically typed, tree-walked language. A build
  description is a program: functions, loops, conditionals, and imports
  declare work. Optional type annotations are checked by `rattsc --lint`.
- Evaluating specs yields a **DAG**: artifacts (files) + actions (commands
  or deferred Rattscript). `rattbuild` executes it or exports it.
- **Two phases.** *Construction* (graph declaration) must be pure and
  deterministic — no `fs.write`, `proc.run`, wall clock, or unsorted
  listings. Violations raise `E_PHASE_VIOLATION`. *Execution* (`action`
  blocks) runs only when outputs need rebuilding. `rattsc` standalone
  scripts are a third context: effects allowed, `action` runs immediately.
- **Node identity** = BLAKE3 hash of (inputs, action recipe, toolchain
  fingerprint). Rebuilds are content-driven, not timestamp-driven.
- **Packages are separate from builds.** `rattpkg` resolves/fetches/verifies
  dependency trees and writes `Rattpkg.lock`. `rattbuild` only reads
  already-fetched trees and never touches the network.

File roles: `Rattspec` (root, one `project(...)`), `Rattspec.m`
(subordinate, `module(...)` — filename *and* call must agree),
`Rattpkg` (package + `deps`), `Rattpkg.lock` (generated TOML),
`*.ratt` (libraries/scripts), `*.in` (template-preprocessed sources).

## 2. Hello world (C executable)

`hello/Rattspec`:

```ratt
project(name: "hello", version: "1.0.0", kind: "single")
import "fs"
import "target"

target.executable(
  name: "hello",
  language: "c",
  sources: fs.glob("src/**/*.c"),
  flags: ["-Wall", "-Wextra"]
)
```

```sh
rattbuild build            # or: rattbuild (build is the default)
./build/hello
rattbuild build            # second run: 0 built, 1 up to date
rattbuild build hello      # select targets AFTER the build command
rattbuild build -C hello -j 4
rattbuild build --dry-run  # preview stale work, runs nothing
rattbuild graph --json -o graph.json
rattbuild graph --dot -o graph.dot   # dot -Tsvg graph.dot -o graph.svg
rattbuild clean
```

Notes: `rattbuild hello` does **not** select target `hello` (first
positional is the command). Languages are `c`, `cxx`, `d`.
`target.library(...)` makes a static lib (`shared: true` → shared).
Link with `deps:`, add `inputs:`/`headers:` for tracked files,
`raw_inputs:` for template resources tracked by original bytes.
Headers are **not** auto-discovered — declare them
(`headers: fs.glob("src/**/*.h")`) or header edits won't rebuild.

## 3. Custom actions

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

`command: ["prog", "args..."]` is the non-script alternative. Failed
commands and missing outputs fail the build. Sandbox: Bubblewrap on POSIX
/ `sandbox-exec` on macOS when available; `sandbox: false` opts out
(e.g. the repo's own DUB bootstrap).

## 4. `rattbuild` cheat sheet

```
rattbuild [build [TARGET ...]] [OPTIONS]
rattbuild graph [--json | --dot] [-o FILE] [--import SAVED]
rattbuild export --to=cmake|gnumake|ninja|meson|<plugin.so> [-o DIR] [-C DIR]
rattbuild clean [--import SAVED]
rattbuild --init [--profile=NAME] [--scaffold] [-C DIR]
rattbuild --list-profiles
```

Key flags: `-C DIR` (project root; spec-relative paths stay spec-relative,
CLI `--import`/`-o`/`--to` paths stay shell-relative),
`-j N` (0 = `build.jobs` = CPU count), `--warnings-as-errors` (use in CI),
`--hermetic` (strict frozen-graph execution; see `manual/25-hermetic-builds.md`).
`graph` never executes actions; `--import` replays a saved JSON/DOT graph
(payload must be preserved verbatim for DOT round-trips).
`clean` removes declared outputs + project cache + `.rattpack/`, not
arbitrary `build/` contents. Exported systems call back into the Rattpack
host via internal `__run-action` — that is not a user command.

## 5. Modules and monorepos

Subdirectories are discovered automatically — never import them by path.
A subordinate spec is **both** named `Rattspec.m` **and** calls
`module(name:)`; any other combination is `E_IDENTITY_MISMATCH`.
Targets address as `module::target`.

Root with nested projects must declare `kind: "monorepo"` plus membership:

```ratt
project(name: "workspace", version: "1.0.0", kind: "monorepo")
monorepo {
  member "libs/first"            # own identity, project::target namespace
  vendored "third_party/second"  # upstream identity preserved
  ignore "third_party/unused"    # has a Rattspec but is not loaded
}
```

An undeclared nested spec triggers `W_UNDECLARED_NESTED_SPEC`: merged
namespace (collisions), shared caches/lockfiles (races), serialized
subgraph (no parallelism). Treat as error in CI.

## 6. Configuration and profiles

Config: `$XDG_CONFIG_HOME/rattpack/Config.toml`
(`%APPDATA%\rattpack\Config.toml` on Windows); `Config.yaml` accepted,
TOML wins with `W_DUAL_CONFIG`. Read-only in specs via
`env.get("toolchain.c")`. Relevant keys: `user.*`, `toolchain.c/cxx/d`,
`build.jobs`, `build.cache_dir`, `pkg.registry`, `pkg.mirrors`.

```sh
rattbuild --init --list-profiles
rattbuild --init --profile=cxx-exe [--scaffold] [-C DIR]
```

Shipped profiles: `c-exe`, `c-lib`, `cxx-exe`, `cxx-lib`, `d-exe`,
`d-lib`, `monorepo`, `empty` (default; builds `build/welcome.txt`).
Custom profiles are `.in` templates in the config `buildprof/` dir using
`@{expr}`, `@if/@else/@end`, `@foreach x in xs/@end` over config values
plus `cwd`, `dirname`, `user`, `date`. Any `*.in` file is preprocessed
the same way.

## 7. Packages with `rattpkg`

`Rattpkg`:

```ratt
package(name: "app", version: "1.0.0", license: "MIT")
deps {
  dep "library" from: registry, version: "^1.0"
  dep "source" from: git("https://example.org/source.git"), tag: "v1.2.0"
  dep "archive" from: http("https://example.org/archive.tar.xz"),
      sha256: "<64 hex digits>"
}
```

Sources: `registry` (HTTP(S) + mirrors), `http`/`ftp` (archive + mandatory
`sha256`; tar/tar.gz/tar.xz/zip, traversal- and link-safe extraction),
`git` (no `Rattpkg` required — synthesizes from `Rattspec` or raw tree;
pin `tag:`/`rev:`; `branch:` needs `--allow-floating`).

```sh
rattpkg resolve              # write Rattpkg.lock + populate cache
rattpkg resolve --update     # force fresh resolution
rattpkg fetch                # fill gaps from existing lock, no re-resolution
rattpkg verify               # re-hash pinned trees, downloads/repairs nothing
```

Commit `Rattpkg.lock` for apps, not for libraries. Cache:
`$XDG_CACHE_HOME/rattpack/pkgs/<name>/<tree-hash>/`. Inside specs query
with `pkg.get("name")`. Registry protocol: `docs/registry.md`.

## 8. Exporters and plugins

```sh
rattbuild export --to=ninja -o generated/ninja
# cmake | gnumake (=make) | meson similarly; default dest: build/export/<exporter>
sh tools/build-plugins.sh
rattbuild export --to=build/plugins/ninja.so -o generated/plugin
```

Exporters see only the serialized DAG and emit frozen rules; specs need
not be present at execution time. Plugins are D shared libs exporting
`rattpack_plugin_entry()` → `RattPluginV1*` (`source/rattpack/plugin/abi.d`);
vtable is append-only. Kinds: `exporter`, `fetcher`, `toolchain`,
`stdlib`. Must match host D compiler family/major or `E_PLUGIN_ABI`.
Anything expressible in Rattscript belongs in `.ratt`, not a plugin.
Details: `docs/plugins.md`.

## 9. Rattscript and `rattsc`

```sh
rattsc program.ratt
rattsc --lint program.ratt
rattsc -e 'fn square(x: int) -> int { return x * x } print(square(7))'
rattsc                       # REPL (ratt> ), :q quits, ... continues brace blocks
rattsc --test tests/script   # golden: *.ratt vs sibling *.expected, byte-exact
```

Values: `nil`, bool, int64, float, str, path, list, map, set, fn
(lexical closures), target, rule, pkg. Statements: `let`/`var`/`const`,
`if/else`, `while`, `for x in xs`, `return`/`break`/`continue`,
`import`. Newlines/semicolons separate statements; `name: value` for
named args. `--lint` checks annotations + statically imported modules
(incl. `.in`) without running their top level — but it is not a full
spec validator.

Stdlib (embedded, import by bare name): `fs`, `path`, `proc`, `str`,
`toolchain`, `target`, `pkg`, `env`, `log`, `collections`, `list`,
`dict`, `sets`, `iter`, `functional`, `math`, `stats`, `json`, `regex`,
`base64`, `semver`. Language: `docs/rattscript.md`; library API:
`manual/06-standard-library.md`; workflows: `manual/20-*.md`–`23-*.md`;
writing reusable modules: `manual/24-*.md`.

## 10. `rattspec` (AI-assisted specs) and directory maps

```sh
rattspec assist 'add these libraries: fmt and zlib' --opencode
rattspec assist 'build a C library and an exe that links it' --openai \
  --openai-url http://127.0.0.1:8000/v1 --openai-user builder --model my-model
rattspec assist 'turn this into a monorepo' --dry-run
rattspec map . --print
```

`assist` rewrites root `Rattspec`/`Rattpkg` from natural language.
Backends: `--opencode` (OpenCode V2 CLI, `--standalone` by default) or
`--openai` (any OpenAI-compatible server via vendored client; bearer key
or basic auth; `/chat/completions` or `/responses`). Defaults/tooling in
`$XDG_CONFIG_HOME/rattpack/Rattpack.json` (flag > env > file > builtin;
see `man/rattspec.1` for `OPENAI_*`/`RATTPACK_*` names). Proposals are
parsed, linted, and manifest-checked before any atomic write; concurrent
edits, backend failures, and bad responses raise `E_ASSIST`. Model output
is never executed. It never writes `Rattpkg.lock` — run `rattpkg resolve`
afterwards. `map` caches a binary inventory
(`.cache/rattpack/<dirname>.bin`, mmap-read, `E_MAP` on stale/unreadable)
that `assist` attaches so large trees stay one short inventory.

## 11. Editor support

`addons/` ships Vim / Neovim (0.8+, native LSP) / Sublime Text packages
for Rattscript, specs, and templates; `ratt-language-server` provides
diagnostics, completion, hover, definitions, symbols. Installed under
`share/rattpack/addons/`; setup: `addons/README.md`.

## 12. Troubleshooting

- `E_PHASE_VIOLATION`: effectful call during construction — move it into
  an `action` (wrapping it in a helper changes nothing).
- `E_IDENTITY_MISMATCH`: fix the spec file (`Rattspec.m` + `module(...)`),
  never relax the check.
- `W_UNDECLARED_NESTED_SPEC` / `W_DUAL_CONFIG`: fix the monorepo block /
  remove one config file; `--warnings-as-errors` in CI.
- Stale build / missed rebuild: every file an action reads belongs in
  `inputs:`/`sources:`/`headers:`/`raw_inputs:`; `fs.read` alone registers
  nothing. Editing an output invalidates its cache entry by content.
- `rattpkg` confusion: `resolve --update` picks versions; `fetch` only
  fills the lock; `verify` only re-hashes.

All codes + recovery: `docs/diagnostics.md`, `manual/17-diagnostics.md`.
New diagnostics require a code, a docs entry, and a golden test
(per `AGENTS.md`).

## 13. Where next

| Goal | Read |
|---|---|
| Full install/build matrix | `manual/02-installation.md` |
| CLI flags for all five binaries | `manual/04-command-line.md` |
| Targets, native lowering, deps | `manual/07-projects-and-targets.md` |
| Actions, scheduler, caches, interchange | `manual/08-actions-and-graphs.md` |
| Hermetic/reproducible builds | `manual/25-hermetic-builds.md` |
| Recipes (generated files, tests, variants) | `manual/19-recipes.md` |
| Contributing, tests, formatting | `AGENTS.md` §10, `manual/18-development.md` |
