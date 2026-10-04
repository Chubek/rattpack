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

## 4.4 `rattsc`

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
