# 17. Diagnostics and troubleshooting

[Previous: Portability and automation](16-portability-and-automation.md) · [Contents](README.md) · [Next: Development](18-development.md)

## 17.1 Diagnostic format and exit status

Most coded diagnostics include a source location:

```text
/work/project/Rattspec:12:5: E_TYPE: expected int, got str
```

The fields are filename, one-based line, one-based column, stable diagnostic
code, and message. Loader/scheduler failures without a more specific location
can use `<input>:1:1`. Some outer CLI exception handling displays a code and
message without a precise source location.

| Exit status | Meaning |
| --- | --- |
| `0` | Command succeeded, or help/version was requested |
| `1` | Application diagnostic or failing golden tests |
| `2` | Argument parsing failed |

Normal command/log output is stdout; diagnostics and displayed build warnings
are stderr. Preserve both streams in automated logs. `proc.run` returns one
captured process-output field, not separate stdout/stderr fields.

`--warnings-as-errors` promotes supported configuration/spec warnings into
failures without renaming their codes. A promoted `W_UNDECLARED_NESTED_SPEC`
is still a `W_*` diagnostic, not a new `E_*` code.

## 17.2 Language and phase diagnostics

| Code | Typical cause | Resolution |
| --- | --- | --- |
| `E_PARSE` | Bad syntax, missing delimiter, unsupported escape, duplicate named argument in source, or overflowing numeric literal | Correct the indicated source; check multiline operator placement and quoted import names |
| `E_NAME` | Undefined/duplicate binding, missing map key, unknown member | Correct spelling/scope, declare once per environment, or test key membership before access |
| `E_TYPE` | Wrong value kind, incompatible operator, annotation mismatch, invalid assignment location | Use documented types and explicit conversions; keep path manipulation in the path module |
| `E_ARITY` | Missing/excess/duplicate function arguments or an empty process command | Match the signature and documented named-argument spelling |
| `E_PHASE_VIOLATION` | Effectful operation reached during construction | Defer it to a target action; read graph settings through `env.get` |
| `E_RUNTIME` | Division by zero, integer overflow, failed assertion, invalid loop control, index bounds, or another evaluation exception | Fix the operation/input; use the detailed message to locate the actual failure |
| `E_IMPORT` | Unknown/missing/cyclic module, standalone import of a project-only module, or explicit spec import | Use path-bearing source imports, break cycles, and let the spec loader discover specs |

Static lint catches inferable type mismatches in unexecuted code but does not
validate every runtime API or construct the build graph. Conversely, a build
that executes one branch does not lint every uncalled function. Use both where
appropriate.

The current evaluator has a known `for`/`foreach` loop-control issue: reaching
`break` or `continue` inside those loops reports `E_RUNTIME` as though the
statement were outside a loop. Use guarded iteration or a `while` loop as
described in [chapter 5](05-rattscript.md). The same statements work in `while`.

## 17.3 Build, configuration, and plugin diagnostics

| Code | Typical cause | Resolution |
| --- | --- | --- |
| `E_IDENTITY_MISMATCH` | `Rattspec.m` calls `project`, root-style spec calls `module`, both styles exist in one directory, or identity declaration is missing/repeated | Correct both filename and identity declaration; keep one style per directory |
| `E_SPEC` | Missing root spec, invalid kind, no root target, invalid member declaration, existing spec during init | Select the correct root and supply valid project/member metadata and a target |
| `E_TARGET` | Empty/duplicate target name, conflicting output, unknown dependency, missing input/compiler, empty compiled source list, or target without work | Inspect target fields, qualified names, glob results, and toolchain paths |
| `E_CYCLE` | Dependency cycle or no schedulable ready action | Remove the cyclic prerequisite relationship |
| `E_ACTION` | Failed command, absent declared output, write outside allowed directories, or checked process failure | Examine the tool output, output spelling, working directory, and action write scope |
| `E_GRAPH` | Invalid graph/version/payload, inconsistent identities, or exporter callback failure | Regenerate the serialization/export from a valid graph; retain the DOT payload |
| `E_CONFIG` | Malformed TOML/YAML, invalid config root, or negative build-job setting | Correct the selected user config and its value types |
| `E_TEMPLATE` | Missing/invalid profile, unclosed substitution/directive, or expression error while rendering | Check template syntax, context variables, and the rendered language's quoting |
| `E_PLUGIN_ABI` | Missing library/entry symbol, incompatible ABI/compiler, empty name, or missing capability callback | Rebuild/deploy the plugin with the host's headers/compiler/shared runtime |
| `E_CLI` | Unknown command or invalid operational argument combination | Consult that application's `--help` and the command-line reference |

## 17.4 Package diagnostics and warnings

| Code | Typical cause | Resolution |
| --- | --- | --- |
| `E_PACKAGE` | Invalid manifest/lock, invalid source name/pin, incompatible ranges, download/Git/extraction failure, or missing package lookup | Check the manifest/lock and underlying source/format details; prepare fetched dependencies before building |
| `E_CHECKSUM` | Missing/invalid archive hash, changed archive bytes, modified cache, or tree disagreement with the lock | Verify the expected distribution bytes; remove the affected invalid cached tree and fetch the pinned content again |
| `E_FLOATING` | Fresh branch resolution without opt-in | Pin a tag/revision, or resolve explicitly with `--allow-floating` |
| `W_DUAL_CONFIG` | Both config formats exist | Keep the intended config file; TOML currently takes precedence |
| `W_UNDECLARED_NESTED_SPEC` | Nested root-style spec was not declared independently | Use monorepo `member`/`vendored`/`ignore`, or convert the shared subtree to a subordinate module |

The stable code list and repository golden-test mapping are also available in
[`docs/diagnostics.md`](../docs/diagnostics.md).

## 17.5 The executable cannot start

If the operating-system loader fails before a Rattpack diagnostic:

1. Confirm that the executable and Rattpack shared library are deployed together.
2. Confirm availability of the corresponding compiler's shared D runtime.
3. Check that host and plugin/application libraries were built with the intended
   compiler family and architecture.
4. Check system-library dependencies and platform library-search configuration.

Use the platform's loader-inspection tools when needed, such as `ldd` on Linux
or `otool -L` on macOS. The Linux source build uses `$ORIGIN`, and macOS uses
`@loader_path`; moving only the executable can break the expected layout.

## 17.6 Root spec or sources are not found

`-C` must name a directory directly containing the root. There is no parent
search. Source globs are relative to each spec's context and omit hidden paths
and symlink files. The profile's default source pattern may not match your
extension or layout.

Inspect the source list in a standalone script with the same working directory,
or replace the glob temporarily with explicit filenames. Do not expect
construction-time `print` in a spec to use the standalone CLI's output callback.

When using `pkg.get`, confirm the appropriate root/member lockfile and run
`rattpkg fetch` in that package root. `rattbuild` does not fetch on demand.

## 17.7 A build skips work after an input changed

Check whether the changed file is tracked:

- Compiler-discovered headers need explicit `headers:`/`inputs:` declarations.
- `include_dirs:` does not track directory contents.
- An action's `fs.read` or subprocess read does not add a graph input by itself.
- Generator scripts and external tool identities need suitable tracking.
- Process environment read during execution is not automatically a cache key.

Inspect `rattbuild graph --json`. The relevant action's input list should include
the file or a producer relationship that explains it. Correct the declaration
before clearing caches; otherwise the next cache entry has the same omission.

For exports, check whether the outer build system uses timestamp rules. Native
Rattpack output-tamper detection is not automatically performed on every
CMake/Make/Ninja invocation. Re-export changed captured recipes/configuration.

## 17.8 A build reruns unexpectedly

An action can become stale due to input bytes, deleted/modified outputs,
toolchain bytes/version output, captured config, command/snapshot changes, or a
different checkout/working path. A downstream recipe can change through an
upstream action identity even if the resulting upstream output text is identical.

Repeated cache misses can also mean the chosen cache path changes between
invocations, cache data is unreadable, or an external process edits outputs
after the build. Prefer an absolute `build.cache_dir`, and inspect output paths
for another writer. Native freshness is content-based, so touching a timestamp
alone is not the ordinary cause of native rebuilds.

## 17.9 An action exits successfully but the build fails

The declared output must exist at its resolved path after execution. Check:

- The output is a file, not merely a directory the command created.
- The command wrote under the spec's action working directory or used an
  appropriate absolute path.
- A shell operator was not mistakenly supplied as a literal argv item.
- The action did not rely on another target's undeclared or unordered side effect.

For a test/checker that does not naturally produce a file, write a success stamp
after the checked process finishes. [Chapter 19](19-recipes.md) shows the pattern.

## 17.10 A package checksum fails repeatedly

Separate archive bytes from extracted-tree identity. A changed archive requires
its correct source checksum and, when intentionally updating, a reviewed new
resolution. A cached tree modified by compilation is a different problem.

`fetch` rejects an existing invalid tree rather than silently replacing it.
Remove the affected `<cache-home>/rattpack/pkgs/<name>/<tree-hash>/` entry, then
fetch using the existing lock. If freshly acquired content still disagrees with
the lock, inspect the pinned source and metadata behavior instead of changing
the lock's hash blindly.

Extra files, directory entries, symlink target changes, and executable-bit
changes can all matter. Keep build outputs outside package-cache trees. Do not
use graph `clean` as a package repair command; it does not clear packages.

## 17.11 An exported build uses old settings

This is expected for a frozen recipe: settings and construction-time captures
come from the export. Re-export after config/helper/template/source-list changes.
The original spec's absence is not itself a failure; exports intentionally run
without reevaluating it.

If you moved the checkout, toolchain, or Rattpack installation, regenerate an
export with the new paths. A saved graph is not an automatic relocatable package.

## 17.12 A plugin loads unsuccessfully

Inspect the shared-library dependencies and the exact exported entry symbol.
The callback ABI is `extern(D)`, even though the entry symbol is unmangled.
Initialize the imported `RattPluginV1` defaults, fill its name/kind/callback, and
keep its backing data alive.

The plugin must use compatible host headers, compiler family/major, shared D
runtime, architecture, and Rattpack library linkage. The selected kind must
provide the required callback. Passing a fetcher or stdlib plugin to
`rattbuild export --to=...` does not register it as an exporter.

## 17.13 Useful failure context

When recording a reproducible failure, retain:

- The application version and exact invocation, including current directory.
- Selected compiler paths and relevant configuration values.
- Full stdout/stderr and exit status.
- The smallest spec/manifest/source set demonstrating the problem.
- A JSON/DOT graph where construction succeeds but execution fails.
- Relevant lock entries and the distinction between fresh and restored caches.

Construction failures need the source spec, while frozen execution failures
often need the graph and its referenced inputs. This distinction makes a
reproduction substantially easier to investigate.
