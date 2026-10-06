# 4. Command-line reference

[Previous: First project](03-first-project.md) · [Contents](README.md) · [Next: Rattscript](05-rattscript.md)

## 4.1 General conventions

All applications support `--help` and `--version`. Long options with values can
be written as `--option=value` or with a separate value. Examples use explicit
commands to make the first positional argument unambiguous.

`-h` is the short help option. Boolean long options also accept the parser's
negative spelling, such as `--no-dry-run` or `--no-warnings-as-errors`; the help
output displays these as `--[no-]name`.

Use one operational mode per invocation. The option parser accepts some flags
whose effects are specific to a command; supplying them to a different command
does not turn that command into another operation.

The exit statuses are:

| Status | Meaning |
| --- | --- |
| `0` | Successful command, help, or version display |
| `1` | Application diagnostic, execution failure, or failing golden tests |
| `2` | Command-line argument parsing failure |

A syntactically parsed but unknown command produces `E_CLI` and status 1.
Diagnostics are written to standard error. Normal command results, build logs,
and Rattscript `print` output go to standard output.

## 4.2 `rattbuild`

### Synopsis

```text
rattbuild [build [TARGET ...]] [OPTIONS]
rattbuild graph [OPTIONS]
rattbuild export --to=EXPORTER [OPTIONS]
rattbuild clean [OPTIONS]
rattbuild --init [--profile=NAME] [--scaffold] [-C DIRECTORY]
rattbuild [--init] --list-profiles
```

Without a positional command, the default is `build`. Selected target names
follow the `build` command. Namespaces form part of the name, for example
`core::codec` or `math::libmath`.

### Public options

| Option | Argument / default | Effect |
| --- | --- | --- |
| `-C`, `--directory` | Directory; `.` | Select the root containing `Rattspec` |
| `-j`, `--jobs` | Nonnegative integer; `0` | Maximum simultaneous native-build actions; zero consults config, then CPU count |
| `--warnings-as-errors` | Boolean flag | Promote configuration/spec warnings to failures, retaining their `W_*` codes |
| `--init` | Boolean flag | Write a root spec from an initialization profile |
| `--scaffold` | Boolean flag | With `--init`, also create the shipped profile's buildable source/package scaffold |
| `--profile` | Profile name | Choose the profile for `--init`; default is `empty` |
| `--list-profiles` | Boolean flag | List installed profile names and exit |
| `--dot` | Boolean flag | Use DOT output for `graph` |
| `--json` | Boolean flag | Request the default JSON graph form |
| `--import` | Graph filename | Use a saved JSON/DOT graph instead of loading specifications |
| `-o`, `--output` | Path | File for `graph`; destination directory for `export` |
| `--to` | Exporter name or library path | Choose `cmake`, `gnumake`/`make`, `ninja`, `meson`, or a native exporter |
| `--hermetic` | Boolean flag | Mark graph actions strict; enforce frozen input/tool identities and declared execution access |
| `--dry-run` | Boolean flag | Preview native build work without executing actions |
| `--version` | Boolean flag | Print application version and exit |

`graph` emits JSON when `--dot` is absent; `--json` is an explicit spelling of
that default. If both format flags are supplied, the implementation selects DOT.

`--list-profiles` lists profiles and exits even when combined with `--init`; it
does not create a spec in that invocation. Listing and initialization install
missing shipped profiles into the user profile directory.

### `build`

```sh
rattbuild build
rattbuild build app generated-header -j 8
rattbuild build math::library -C workspace
rattbuild build --import saved.json
rattbuild build --hermetic
```

With no selected names, all graph actions are considered. With names, the
scheduler visits those actions and their transitive prerequisites. Loading and
validating the specification still happens for the entire project tree: selecting
one target does not skip construction errors in other declarations.

Native builds print `build NAME` for executed work and a final built/up-to-date
count. A dry run counts stale actions as work that would be built and does not
update cache entries.

`--hermetic` also applies to graph capture and export, preserving strict action
flags in the saved DAG. Strict subprocess execution requires a supported
backend; pure Rattscript actions use interpreter-level file checks. See
[chapter 25](25-hermetic-builds.md) for declarations and replay examples.

### `graph`

```sh
rattbuild graph
rattbuild graph --dot -o graph.dot
rattbuild graph --import graph.dot --json -o graph.json
```

Construction runs, but execution-time actions do not. With no `-o`, the
serialization is written to stdout. DOT contains a canonical graph payload
needed for lossless reimport; preserve that payload when editing or processing
the file.

### `export`

```sh
rattbuild export --to=ninja -o generated/ninja
rattbuild export --to=cmake -C project -o generated/cmake
```

The default destination is `<selected-project>/build/export/<exporter>`. Give an
explicit destination when using a plugin path. The command exports the complete
graph and reports its exporter name and destination. Native build systems then
invoke the recorded Rattpack host to execute frozen actions.

### `clean`

```sh
rattbuild clean
rattbuild clean --import saved.json
```

Cleaning removes graph-declared generated files and the graph root's cache and
local working directory. It does not remove cached packages. Positional target
selection is a `build` feature; `clean` is graph-wide.

### Path resolution

`-C` changes the selected project root, not the process working directory.
Relative CLI paths supplied to `--import`, `-o`, and a plugin `--to` path are
resolved from the shell's current directory. Paths declared inside a build spec
are resolved from the spec context. Imported graphs retain their saved root;
`-C` does not relocate their recorded paths.

### Internal action runner

Generated exporter files use the internal `__run-action` command and hidden
options such as `--graph`, `--action`, `--stamp`, and `--incremental-action`.
They are an implementation interface for frozen action execution, not normal
project configuration options. Use `build --import` for manually executing a
saved graph with dependency scheduling.

## 4.3 `rattpkg`

### Synopsis

```text
rattpkg resolve [--update] [--allow-floating] [-C DIRECTORY]
rattpkg fetch [-C DIRECTORY]
rattpkg verify [-C DIRECTORY]
```

Exactly one package command is required. There is no default package operation
or positional package-selection argument.

| Option | Effect |
| --- | --- |
| `-C`, `--directory` | Select the directory containing the manifest/lockfile; default `.` |
| `--update` | Request fresh resolution instead of reusing a matching lockfile |
| `--allow-floating` | Permit Git branch references when resolving new selections |
| `--version` | Print the version and exit |

`resolve` reads `Rattpkg`, obtains required content, and writes `Rattpkg.lock`.
If an existing lock has the same manifest fingerprint and `--update` is absent,
it reuses that lock and fetches/verifies its pinned content.

`fetch` reads the existing lock and fills missing package-cache entries. It
checks existing entries too. It does not choose newer versions or update the
lockfile.

`verify` re-hashes all locked package trees. It neither downloads missing trees
nor repairs changed ones. These commands finish with `resolved Rattpkg.lock`,
`packages fetched`, or `packages verified` on success.

There are no `install`, `publish`, `remove`, or `search` package subcommands in
this release. Package consumption is through already-fetched source trees.

## 4.4 `rattspec`

### Synopsis

```text
rattspec assist REQUEST [-C DIRECTORY] [--opencode | --openai] [OPTIONS]
rattspec map DIRECTORY [--print] [--map-out PATH] [--no-summary]
```

`rattspec` has two commands. `assist` creates and updates the two root files,
`Rattspec` and `Rattpkg`, from a natural-language request. `map` scans a
directory into a compact binary map and can print its terse text form.

Assist requires the matching plugin, `opencode-assist` or `openai-assist`, and
for the OpenCode backend, OpenCode V2 on `PATH`.

### Assist backends

| Backend | Transport | Credentials |
| --- | --- | --- |
| `--opencode` | The `opencode api` CLI, so OpenCode's own service discovery and authentication apply | Handled by the CLI; launched with `--standalone` by default |
| `--openai` | The vendored `openaipp` client, linked only into that plugin | Bearer API key, or HTTP basic user and password |

The two flags are mutually exclusive. Without either, the backend comes from
`Rattpack.json`. OpenCode accepts `provider/model` or `provider/model#variant`;
the OpenAI backend takes a plain model name and uses `/chat/completions` by
default, or `/responses` with `--openai-api responses`.

The OpenCode one-shot generation API uses the server's base configuration to
choose a model when `--model` is omitted. A model selected in an interactive
session does not set this default. If assist reports `HTTP 400 Bad Request`
with `No model specified and no supported model is available`, select an
available model explicitly with `--model provider/model` (optionally
`#variant`), or set `opencode.model` in `Rattpack.json` or the
`RATTPACK_OPENCODE_MODEL` environment variable. List models with
`opencode api get /api/model --standalone`. If none are available, connect a
provider using `/connect` in OpenCode and check its configuration and
credentials. API failures include both the CLI's HTTP status and the server's
error body.

### Options

| Option | Effect |
| --- | --- |
| `-C`, `--directory` | Project directory for `assist`, default directory for `map` |
| `--opencode` / `--openai` | Select the assist backend |
| `--plugin` | Plugin path; default is the backend's plugin beside the executable |
| `--opencode-executable` | OpenCode executable name or path; default `opencode` |
| `--server` | Explicit OpenCode server URL |
| `--standalone` / `--no-standalone` | Private OpenCode server; default on |
| `--openai-url` | OpenAI-compatible base URL, including any path prefix |
| `--openai-key` | OpenAI bearer API key |
| `--openai-user` / `--openai-password` | OpenAI basic-auth credentials; these take precedence over the key |
| `--openai-api` | `chat` or `responses`; default `chat` |
| `--model` | Model selection for the chosen backend |
| `--timeout` | Request deadline in seconds; default 120 |
| `--dry-run` | Print the validated proposal as JSON and write nothing |
| `--map-out` | Binary map destination for `map` |
| `--print` | Print rendered map text after writing the binary map |
| `--summary` / `--no-summary` | Directory totals in rendered text; default on |

### Assist

```sh
rattspec assist 'add these libraries: fmt and zlib' --opencode
rattspec assist 'build a C library and an exe that links it' --openai \
    --openai-url http://127.0.0.1:8000/v1 --openai-user builder --model my-model
rattspec assist 'make this a monorepo' --dry-run
```

The command reads the existing `Rattspec`/`Rattpkg`, a bounded path inventory,
and the cached directory map when one exists, then expects a JSON object of
complete replacement files. Unchanged files may be omitted; a missing file must
be created.

Nothing is written until the whole proposal is validated: each file must parse,
lint, declare exactly one `project()`/`package()` identity, and declare at least
one target in a `Rattspec`. A proposed `Rattpkg` is additionally read by the real
manifest reader, so dependency sources, Git pins, and checksums are host-validated
rather than trusted. Model output is never evaluated as Rattscript.

Files are written atomically, and only if they still match the content read
before the request. An edit made while the model was generating raises
`E_ASSIST` instead of overwriting it. `E_ASSIST` also reports an unreachable
backend, a failed or timed-out request, and an unusable response.

Assist does not run `rattpkg resolve` and never writes `Rattpkg.lock`. The
model's summary names any follow-up step it expects.

### Configuration

Tooling settings are read from `$XDG_CONFIG_HOME/rattpack/Rattpack.json`
(`%APPDATA%\rattpack\Rattpack.json` on Windows). This file is independent of
`Config.toml`: it configures host tools and is never read by a build graph.

```json
{
  "backend": "openai",
  "openai": {
    "base_url": "http://127.0.0.1:8000/v1",
    "user": "builder",
    "password": "secret",
    "model": "local-model",
    "api": "chat"
  },
  "opencode": { "standalone": true },
  "map": { "summary": true, "max_entries": 200000 },
  "scripts": { "scaffold": "tools/scaffold.ratt" },
  "commands": { "format": "clang-format" }
}
```

Every value resolves in the order **command-line flag, environment variable,
this file, built-in default**. Recognised environment names include `OPENAI_BASE`,
`OPENAI_API_KEY`, `OPENAI_USER`, `OPENAI_PASSWORD`, `OPENAI_ORG_ID`,
`OPENAI_PROJECT_ID`, `OPENAI_MODEL`, `OPENCODE`, `RATTPACK_OPENCODE_SERVER`,
`RATTPACK_OPENCODE_MODEL`, `RATTPACK_OPENCODE_STANDALONE`, and the matching
`RATTPACK_OPENAI_*` and `RATTPACK_OPENCODE_TIMEOUT` names. See
`man/rattspec.1` for the complete list.

### `map`

```sh
rattspec map . --print
rattspec map src --map-out /tmp/src.bin
```

`map` writes `$XDG_CACHE_HOME/rattpack/<directoryname>.bin`. `assist` reuses
that cache, so a large project is described by one short inventory instead of a
long path list.

The text form is one entry per line, indented one space per depth, with a colon
separating a name from its attributes. A backslash escapes a backslash, colon,
or space inside a name.

```text
d NAME:F COUNT:B BYTES   directory, totals for everything below it
f NAME:X:BYTES:HASH      file; X marks an executable
l NAME                   symbolic link
x NAME                   any other entry kind
```

```text
d demo:F6:B273.5k
 f README.md:7:b21109ab
 f run.sh:X:10:bc1f407a
 d src:F4:B273.5k
  f main.c:22:0b377551
  d core:F2:B28
   f util.c:19:f86d8b1f
```

`HASH` is eight hex digits of the file's content fingerprint and appears only for
source and build-input types. Version-control metadata, build outputs,
dependency caches, and dot entries are never mapped, and entries are sorted so
the same tree always renders identically. Maps are read back through the
operating system's memory-mapping interface; an unreadable or stale map raises
`E_MAP`.

## 4.5 `rattsc`

### Synopsis

```text
rattsc FILE
rattsc --lint FILE
rattsc -e SCRIPT
rattsc --test DIRECTORY
rattsc
```

| Option | Effect |
| --- | --- |
| `--lint` | Check a source file and statically imported source modules |
| `-e`, `--eval` | Evaluate the supplied source string |
| `--test` | Run `.ratt`/`.expected` golden fixtures under a directory |
| `--version` | Print the version and exit |

For a file, the evaluator's working directory is the file's directory. For `-e`
and the REPL, it is the shell's current directory. Rattscript files ending in
`.in` are preprocessed when run or linted.

`--lint` walks syntax and annotations without executing source-module top-level
statements. It does evaluate template substitutions needed to parse `.in`
sources. It is not a complete build-spec validator or an execution simulator.

### REPL

With no arguments, `rattsc` displays `ratt> `. Bindings persist between inputs.
The value of the final statement is displayed when it is not `nil`.

```text
ratt> let n = 6
ratt> n * 7
42
ratt> :q
```

Use `:q`, `:quit`, or end-of-input to leave. Input with unmatched opening braces
uses the continuation prompt `... `. Continuation detection counts braces;
use a source file for complicated multiline input or strings containing braces.
Runtime diagnostics in the REPL are displayed and the next prompt remains
available.

### Golden tests

```sh
rattsc --test tests/script
```

The runner recursively finds `.ratt` files, captures their output, and compares
it byte-for-byte with the sibling `.expected` file. A diagnostic contributes its
code to the captured output. Missing expected files, mismatches, and an empty
test directory produce a failing status. Repository scenario headers are
described in [chapter 18](18-development.md).
