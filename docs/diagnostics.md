# Diagnostics

Diagnostics include a stable code and, where applicable, a source file, line,
and column. Commands exit with status 1 on a diagnostic and 2 on CLI parsing
errors. `--warnings-as-errors` promotes warnings without changing their codes.

| Code | Meaning and resolution | Golden test |
| --- | --- | --- |
| `E_PARSE` | Malformed Rattscript, invalid escape, or overflowing literal. Correct the syntax at the indicated location. | `e-parse.ratt` |
| `E_NAME` | Undefined binding, missing map key/member, or duplicate binding. Declare the name or correct its spelling. | `e-name.ratt` |
| `E_TYPE` | A value, operation, or annotation has the wrong type. `rattsc --lint` checks annotations before evaluation. | `e-type.ratt` |
| `E_ARITY` | Missing, duplicated, or unknown function argument. Match the declared parameters. | `e-arity.ratt` |
| `E_PHASE_VIOLATION` | An effectful operation was called during graph construction, including through an alias or helper. Move it into an action. | `e-phase.ratt` |
| `E_RUNTIME` | Evaluation failed, such as division by zero, integer overflow, invalid loop control, malformed codec/regex input, or an invalid standard-library domain/count. | `e-runtime.ratt`, `stdlib-*-error.ratt` |
| `E_IMPORT` | Missing/unknown/cyclic module, or an explicitly imported subordinate spec. Let the spec loader discover subordinate specs. | `e-import.ratt` |
| `E_IDENTITY_MISMATCH` | File naming and identity declaration disagree. Subordinates require both `Rattspec.m` and `module()`. | `e-identity.ratt` |
| `E_SPEC` | Invalid/missing project metadata or no declared targets. Supply a root identity and at least one target. | `e-spec.ratt` |
| `E_TARGET` | Invalid/duplicate target, conflicting output, missing source/compiler, or unresolved dependency. | `e-target.ratt` |
| `E_CYCLE` | The build DAG contains a cycle. Remove the circular dependency. | `e-cycle.ratt` |
| `E_HERMETIC` | Strict execution found an undeclared input/output/tool, changed frozen input/tool, an isolation failure, or an unsandboxed action. | `e-hermetic.ratt` |
| `E_ACTION` | A command failed, an output was not produced, or an action violated its write scope. | `e-action.ratt` |
| `E_GRAPH` | Invalid graph format/version, inconsistent content identities, or exporter failure. Re-export the graph. | `e-graph.ratt` |
| `E_CONFIG` | Malformed TOML/YAML or an invalid configuration value. Correct the config file. | `e-config.ratt` |
| `E_TEMPLATE` | Invalid profile/substitution or unmatched template directive. Match `@if`/`@foreach` with `@end`. | `e-template.ratt` |
| `E_PACKAGE` | Invalid manifest/lockfile, incompatible dependency constraints, or fetch/extraction failure. | `e-package.ratt` |
| `E_CHECKSUM` | Missing archive SHA-256 or modified downloaded/cached package content. Use the correct checksum and resolve/fetch again. | `e-checksum.ratt` |
| `E_FLOATING` | A Git branch was requested without `--allow-floating`. Pin a tag/revision or explicitly allow a branch during resolution. | `e-floating.ratt` |
| `E_PLUGIN_ABI` | A plugin has an incompatible ABI/compiler, missing entry point, or missing capability. Rebuild with the host compiler. | `e-plugin.ratt` |
| `E_CLI` | Unknown command or invalid command option combination. Consult `--help`. | `e-cli.ratt` |
| `E_ASSIST` | An assist backend failed, returned an invalid file proposal, or an input file changed during generation. Check the selected backend, its credentials, and retry with current files. | `e-assist.ratt` |
| `E_MAP` | A directory could not be scanned, or a directory map was missing, truncated, of an unknown version, or internally inconsistent. Re-create it with `rattspec map`. | `e-map.ratt` |
| `W_DUAL_CONFIG` | Both config formats exist; TOML takes precedence. | `w-dual-config.ratt` |
| `W_UNDECLARED_NESTED_SPEC` | A nested project was not explicitly declared in a monorepo. It shares identity/resources and is serialized. Declare `member`, `vendored`, or `ignore`. | `w-nested.ratt` |

Golden paths are relative to `tests/script/`. Scenario headers exercise the
corresponding loader/command with isolated temporary project/config directories.
