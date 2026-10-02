# AGENTS.md — Rattpack

This file is the contract between human contributors, AI coding agents, and the Rattpack codebase. Read it fully before modifying anything. When in doubt, prefer the behaviour described here over what you infer from the code; if they disagree, open an issue titled `spec-drift:` and describe the discrepancy.

---

## 1. What Rattpack Is

Rattpack is a **build system and package manager** driven by **Rattscript**, a Turing‑complete, tree‑walked domain‑specific language with a substantial standard library. Rattpack is deliberately portable: the runtime has three platform backends — **Win32**, **macOS** (Cocoa/Darwin), and **POSIX** — behind a single internal `rt.sys` interface.

Rattpack is implemented in **D** (DMD/LDC, `-preview=dip1000` clean) and exposes:

- a **plugin ABI in D** (`extern(D)` with a versioned `RattPluginV1` vtable), and
- an **extension surface in Rattscript** for anything that does not need native code.

### 1.1 Components

| Binary       | Role                                                                                  |
|--------------|---------------------------------------------------------------------------------------|
| `rattbuild`  | Evaluates `Rattspec`, constructs the build DAG, executes it or exports it via plugin. |
| `rattpkg`    | Package manager. Reads `Rattpkg`, resolves and fetches dependencies, verifies them.   |
| `rattsc`     | Standalone Rattscript interpreter / REPL / linter (`rattsc --lint`).                  |
| `librattpack`| Shared library consumed by all of the above and by plugins.                           |

---

## 2. Repository Layout

```text
rattpack/
├── AGENTS.md
├── dub.sdl                  # Root D build description (we dogfood Rattspec too; see §10)
├── Rattspec                 # Rattpack building itself
├── Rattpkg                  # Rattpack's own dependency manifest
├── source/
│   ├── rattpack/
│   │   ├── script/          # Rattscript lexer, parser, AST, tree-walking evaluator
│   │   ├── stdlib/          # Rattscript standard library (fs, proc, str, path, toolchain, …)
│   │   ├── graph/           # Build DAG: nodes, edges, scheduler, hashing, incremental cache
│   │   ├── spec/            # Rattspec / .m loader, project identity, monorepo resolution
│   │   ├── pkg/             # Rattpkg manifest, resolver, fetchers (http/ftp/git), lockfile
│   │   ├── plugin/          # Plugin ABI, loader, built-in exporters
│   │   ├── rt/              # Platform backends: rt/win32, rt/macos, rt/posix
│   │   └── config/          # XDG config, Config.toml / Config.yaml, profiles
│   └── apps/
│       ├── rattbuild/
│       ├── rattpkg/
│       └── rattsc/
├── plugins/                 # First-party exporters: cmake/, gnumake/, ninja/, meson/
├── profiles/                # Default build profiles shipped to $XDG_CONFIG_HOME (*.in)
├── stdlib/                  # Rattscript-side stdlib sources (*.ratt), embedded at build
├── tests/
│   ├── unit/                # D unit tests (unit-threaded)
│   ├── script/              # Rattscript golden tests (*.ratt + *.expected)
│   └── integration/         # End-to-end fixture projects
├── docs/
└── third_party/             # Vendored C libraries only (see §11)
```

---

## 3. Rattscript

### 3.1 Language Summary

- **Evaluation**: tree‑walked. No bytecode stage. Performance work belongs in the evaluator's caching layer, never in a compiler rewrite without an RFC.
- **Typing**: dynamically typed with optional type annotations checked at load time by `rattsc --lint`.
- **Values**: `nil`, `bool`, `int` (64‑bit), `float`, `str`, `path`, `list`, `map`, `set`, `fn`, `target`, `rule`, `pkg`.
- **Modules**: `import "fs"`, `import "./tools/helpers.ratt"`. Standard library modules are namespaced without a path.
- **Purity rule**: Rattscript evaluated during *graph construction* must be deterministic. Side‑effecting stdlib calls (`proc.run`, `fs.write`) are only permitted inside `action` blocks, which run at *graph execution* time. The evaluator enforces this and raises `E_PHASE_VIOLATION`.

### 3.2 Standard Library Modules

| Module      | Purpose                                                        |
|-------------|----------------------------------------------------------------|
| `fs`        | File queries, globbing, hashing, atomic writes                 |
| `path`      | Portable path manipulation, normalisation per backend          |
| `proc`      | Process spawning, environment, exit codes                      |
| `str`       | String utilities, templating used by `.in` preprocessing       |
| `toolchain` | Compiler/linker discovery, flags abstraction                   |
| `target`    | Declaring executables, libraries, custom rules                 |
| `pkg`       | Querying resolved dependencies inside a spec                   |
| `env`       | Read‑only view of the config environment (§6)                  |
| `log`       | Structured diagnostics                                         |

### 3.3 Preprocessed Files (`.in`)

Any file with a `.in` suffix is passed through the Rattscript templating engine (`@{expr}` substitution, `@if/@else/@end`, `@foreach`) before use — the same model as CMake's `configure_file`. Build profiles (§6) are always `.in`.

---

## 4. Rattspec Files and Project Identity

### 4.1 The root `Rattspec`

Every project has exactly one `Rattspec` at its root. It must:

1. Declare `project(name:, version:, kind:)` where `kind` is `single`, `multi-module`, or `monorepo`.
2. Declare at least one `target`.
3. Not import subordinate specs by path — subordinate discovery is automatic (see below).

### 4.2 Subordinate specs (`.m`)

Rattspec files in subdirectories **must** mark themselves subordinate. The canonical way is:

- Name the file `Rattspec.m`, **and**
- Call `module(name:)` instead of `project(...)`, which substitutes the project identity with the subdirectory's identity for the duration of that file.

Both must be done *at the same time*. A `Rattspec.m` that calls `project(...)`, or a plain `Rattspec` in a subdirectory calling `module(...)`, is an error (`E_IDENTITY_MISMATCH`). Agents: never "fix" this error by relaxing the check; fix the spec file.

### 4.3 Monorepos and vendored projects

If a project contains **another Rattpack‑using project** (vendored, third‑party, or a sibling in a monorepo), the root `Rattspec` must declare it explicitly:

```ratt
project(name: "acme", version: "1.4.0", kind: "monorepo")

monorepo {
  member "libs/zap"              # a first-party member
  vendored "third_party/quux"    # someone else's project, identity preserved
  ignore "third_party/legacy"    # has a Rattspec but must not be loaded
}
```

Rationale (do not remove this behaviour): if a nested `Rattspec` is found and the root has not declared `kind: "monorepo"`, `rattbuild` assumes a **multi‑module project** sharing one identity. Consequences of that misassumption:

- The build graph is merged under one namespace → **target name collisions**.
- Resource scopes (output dirs, caches, lockfiles) are shared → **restricted or racing resource access**.
- The scheduler cannot prove independence between subtrees → **parallel building is disabled** for the affected subgraph.

`rattbuild` emits `W_UNDECLARED_NESTED_SPEC` with the offending path. Treat this warning as an error in CI (`--warnings-as-errors`).

---

## 5. Initialising Projects

```bash
rattbuild --init                      # boilerplate Rattspec in CWD
rattbuild --init --profile=<prof>     # from $XDG_CONFIG_HOME/rattpack/buildprof/<prof>.in
rattbuild --init --list-profiles
```

- Profiles live in `$XDG_CONFIG_HOME/rattpack/buildprof/` (Windows: `%APPDATA%\rattpack\buildprof\`). Users may add their own.
- Profiles are `.in` files and are preprocessed (§3.3). The substitution environment is **primarily the config environment** (§6), plus `@{cwd}`, `@{dirname}`, `@{user}`, `@{date}`.
- First‑party profiles shipped in `profiles/`: `c-exe`, `c-lib`, `cxx-exe`, `cxx-lib`, `d-exe`, `d-lib`, `monorepo`, `empty`.

---

## 6. Configuration Environment

Location: `$XDG_CONFIG_HOME/rattpack/Config.toml`. `Config.yaml` is accepted as an alternative; if both exist, `Config.toml` wins and `W_DUAL_CONFIG` is emitted.

```toml
[user]
name  = "Jane Doe"
email = "jane@example.org"
license = "MIT"

[toolchain]
c   = "clang"
cxx = "clang++"
d   = "ldc2"

[build]
jobs = 0            # 0 = logical CPU count
cache_dir = "~/.cache/rattpack"

[pkg]
registry = "https://pkgs.example.org"
mirrors  = []
```

All keys are exposed read‑only to Rattscript via `env.get("toolchain.c")`.

---

## 7. The Build DAG

`rattbuild` evaluates the spec tree and produces a **directed acyclic graph** where nodes are *artifacts* and edges are *actions*. Node identity is a content hash of (inputs, action, toolchain fingerprint).

Two things can be done with the DAG:

1. **Execute it** with Rattbuild's own scheduler (`rattbuild build`). Incremental, parallel, sandboxed per action where the backend allows.
2. **Export it** through a plugin into another build system's input files (`rattbuild export --to=<plugin>`).

First‑party exporter plugins: **CMake**, **GNU Make**, **Ninja**, **Meson**.

Invariants:

- Graph construction must be pure (§3.1). Any PR that makes construction depend on wall clock, PIDs, or unsorted directory listings will be rejected.
- Exporters consume the DAG only; they may never re‑evaluate Rattscript.
- `rattbuild graph --dot` must round‑trip through `rattbuild graph --import` with identical hashes. There is a test for this; keep it green.

---

## 8. Plugin ABI

- Plugins are shared libraries exporting `rattpack_plugin_entry()` returning `RattPluginV1*`.
- ABI is **versioned and additive**. Never reorder or remove vtable fields; append and bump `minor`.
- Plugins are compiled with the same D compiler major version as the host. Mismatch → `E_PLUGIN_ABI`.
- Plugin kinds: `exporter`, `fetcher`, `toolchain`, `stdlib` (adds Rattscript modules).
- Anything expressible in Rattscript should be an `.ratt` extension, not a plugin.

---

## 9. `rattpkg` and the `Rattpkg` Manifest

`Rattpkg` is a Rattscript file that (a) declares the project as a Rattpack package and (b) lists dependencies.

```ratt
package(name: "acme", version: "1.4.0", license: "MIT")

deps {
  dep "zlib"      from: registry, version: "^1.3"
  dep "fmtlib"    from: git("https://github.com/fmtlib/fmt.git"), tag: "11.0.2"
  dep "oldlib"    from: http("https://files.example.org/oldlib-2.1.tar.gz"),
                  sha256: "…"
  dep "legacy"    from: ftp("ftp://ftp.example.org/pub/legacy-0.9.tar.xz"),
                  sha256: "…"
}
```

Dependency sources:

| Source     | Notes                                                                                             |
|------------|---------------------------------------------------------------------------------------------------|
| `registry` | Rattpack packages served over HTTP(S) from the configured registry/mirrors.                       |
| `http(…)`  | Arbitrary archive. `sha256` is **mandatory**.                                                     |
| `ftp(…)`   | As above. `sha256` mandatory.                                                                     |
| `git(…)`   | Any Git remote. A `Rattpkg` in the remote is **not required**; absent one, rattpkg synthesises a package from a `Rattspec`, or treats it as a raw source tree if neither exists. Pin with `tag:` or `rev:`; `branch:` is allowed only with `--allow-floating`. |

Behaviour:

- `rattpkg resolve` writes `Rattpkg.lock` (TOML). Commit it for applications; do not commit it for libraries.
- `rattpkg fetch` populates `$XDG_CACHE_HOME/rattpack/pkgs/<name>/<hash>/`.
- `rattpkg verify` re‑hashes everything in the lockfile.
- Resolution is deterministic given the lockfile; never add network access to `rattbuild` itself.

---

## 10. Building, Testing, Contributing

```bash
dub build -c rattbuild              # bootstrap build via dub
./build/rattbuild build             # then dogfood: build Rattpack with Rattpack
dub test                            # D unit tests (unit-threaded)
./build/rattsc --test tests/script  # Rattscript golden tests
./tests/integration/run.sh          # end-to-end fixtures (needs cmake, ninja, make, meson)
dub run dfmt -- -i source/          # format before committing
dub run dscanner -- --styleCheck source/
```

Rules for agents:

- Run `dub test` and the script golden tests before proposing changes. Integration tests are required for changes under `graph/`, `pkg/`, or `plugins/`.
- Do not introduce new D dependencies without adding them to §11 **and** to `Rattpkg`.
- Every new diagnostic needs a code (`E_*`/`W_*`), an entry in `docs/diagnostics.md`, and a golden test.
- Platform‑specific code goes under `rt/<backend>/` only. `version(Windows)` blocks elsewhere are rejected in review.
- Keep public D APIs `@safe` where possible; document `@trusted` with a `// TRUSTED:` justification comment.
- Commit messages: `component: imperative summary` (e.g. `graph: hash toolchain fingerprint into node id`).

---

## 11. External Dependencies

### 11.1 D packages (resolved via dub, mirrored in `Rattpkg`)

| Package            | Used for                                           | Git remote                                               |
|--------------------|----------------------------------------------------|----------------------------------------------------------|
| `toml`             | Parsing `Config.toml`, `Rattpkg.lock`              | https://github.com/dlang-community/toml                  |
| `dyaml`            | Parsing `Config.yaml`                              | https://github.com/dlang-community/D-YAML                |
| `tinyendian`       | Transitive dependency of `dyaml`                   | https://github.com/dlang-community/tinyendian            |
| `requests`         | HTTP(S) and FTP fetchers                           | https://github.com/ikod/dlang-requests                   |
| `cachetools`       | Transitive dependency of `requests`                | https://github.com/ikod/cachetools                       |
| `automem`          | Transitive dependency of `requests`                | https://github.com/atilaneves/automem                    |
| `test_allocator`   | Transitive test support of `automem`               | https://github.com/atilaneves/test_allocator             |
| `semver`           | Version constraint parsing and comparison          | https://github.com/dcarp/semver                          |
| `msgpack-d`        | On‑disk serialisation of the DAG cache             | https://github.com/msgpack/msgpack-d                     |
| `taggedalgebraic`  | Rattscript value representation                    | https://github.com/s-ludwig/taggedalgebraic              |
| `emsi_containers`  | Allocator‑aware containers in the graph scheduler  | https://github.com/dlang-community/containers            |
| `argparse`         | CLI parsing for all three binaries                 | https://github.com/andrey-zherikov/argparse              |
| `arsd-official`    | `terminal` submodule for coloured diagnostics/REPL | https://github.com/adamdruppe/arsd                       |
| `unit-threaded`    | Test framework (dev only)                          | https://github.com/atilaneves/unit-threaded              |
| `dfmt`             | Formatter (dev only)                               | https://github.com/dlang-community/dfmt                  |
| `dscanner`         | Linter (dev only)                                  | https://github.com/dlang-community/D-Scanner             |
| `libdparse`        | Formatter/linter parser (dev only)                 | https://github.com/dlang-community/libdparse              |
| `libddoc`          | Linter documentation support (dev only)            | https://github.com/dlang-community/libddoc                |
| `dcd`             | Linter symbol lookup, `dsymbol` submodule (dev only)| https://github.com/dlang-community/DCD                   |
| `inifiled`         | Linter configuration parser (dev only)             | https://github.com/burner/inifile-D                       |

### 11.2 Vendored C libraries (`third_party/`, with D bindings in‑tree)

| Library   | Used for                                        | Git remote                                   |
|-----------|-------------------------------------------------|----------------------------------------------|
| `libgit2` | Git fetcher (clone, checkout by tag/rev)        | https://github.com/libgit2/libgit2           |
| `zlib`    | Archive extraction, required by libgit2         | https://github.com/madler/zlib               |
| `xz`      | `.tar.xz` extraction                            | https://github.com/tukaani-project/xz        |
| `blake3`  | Content hashing for DAG node identity           | https://github.com/BLAKE3-team/BLAKE3        |

### 11.3 Toolchain (not vendored)

| Tool          | Purpose                               | Git remote                                   |
|---------------|---------------------------------------|----------------------------------------------|
| `dub`         | Bootstrap build                       | https://github.com/dlang/dub                 |
| `ldc`         | Preferred D compiler                  | https://github.com/ldc-developers/ldc        |
| `dmd`         | Supported D compiler                  | https://github.com/dlang/dmd                 |
| CMake, Ninja, GNU Make, Meson | Exporter integration tests | https://github.com/Kitware/CMake, https://github.com/ninja-build/ninja, https://git.savannah.gnu.org/git/make.git, https://github.com/mesonbuild/meson |

Pin policy: every dub dependency is pinned to an exact version in `dub.selections.json`; vendored C libraries are pinned by submodule commit. Bumping either requires a changelog entry.

---

## 12. Glossary

- **Rattspec** — root build spec; **`Rattspec.m`** — subordinate module spec.
- **Rattpkg** — package manifest; **`Rattpkg.lock`** — resolved lockfile.
- **Build DAG** — hashed artifact/action graph produced by `rattbuild`.
- **Exporter** — plugin that lowers the DAG to another build system.
- **Profile** — `.in` template used by `rattbuild --init`.
- **Config environment** — key/value set from `Config.toml`/`Config.yaml`.
