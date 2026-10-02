# 6. Modules and standard library

[Previous: Rattscript](05-rattscript.md) · [Contents](README.md) · [Next: Targets](07-projects-and-targets.md)

## 6.1 Importing modules

```ratt
import "fs"
import "str" as text
import "./tools/helpers.ratt" as helpers
```

A module name without path separators selects a built-in module. Local source
imports should include a relative or absolute path, for example
`./helpers.ratt`, rather than `helpers.ratt` alone.

With no `as`, the binding is the source basename without its extension.
`./tools/helpers.ratt.in` binds `helpers`: both the template suffix and source
extension are removed. Built-in modules bind their names.

Local imports resolve relative to the **importing source file**. Each source
module executes once per evaluator in a fresh environment whose parent is the
evaluator's globals. Its top-level bindings become the returned module map.
There is no export keyword or private-name filtering.

```ratt
# tools/helpers.ratt
fn stem_label(name: str) -> str { return "object-" + name }
let preferred_mode = "debug"
```

```ratt
# A file in the directory containing tools/.
import "./tools/helpers.ratt"
assert(helpers.stem_label("main") == "object-main")
```

Modules do not inherit the importing file's local bindings. Pass values as
function arguments or import the required module/configuration explicitly.
Cyclic imports are rejected with `E_IMPORT`.

File imports and filesystem operations have related but different bases:

- Import paths are relative to the importing file.
- `fs` paths and most `path` operations use the evaluator's working directory.
- Importing a helper does not change that working directory.

In a build spec, this is the current project/module directory. In a standalone
script, it is the root script's directory. Avoid assuming an imported helper's
`fs.read("data.txt")` is relative to the helper file itself.

Build specifications are discovered separately. Explicit imports of
`Rattspec`, `Rattspec.m`, or their `.in` variants are rejected.

## 6.2 Effects and contexts

Tables below mark calls as **read-only** or **effectful**. Read-only calls are
permitted during construction, although their results still depend on the
queried files or configuration. Effectful calls are forbidden during
construction and permitted in execution or standalone mode.

Native API signatures document argument names used by named calls. Path-taking
APIs generally accept either `str` or `path`; these types are not otherwise
interchangeable for annotations or arithmetic.

## 6.3 `fs`: filesystem operations

```ratt
import "fs"
```

| Call | Result | Phase class |
| --- | --- | --- |
| `fs.exists(path)` | Bool indicating existence | Read-only |
| `fs.is_file(path)` | Bool; false for missing paths | Read-only |
| `fs.is_dir(path)` | Bool; false for missing paths | Read-only |
| `fs.read(path)` | File text; preprocesses `.in` paths | Read-only |
| `fs.hash(path)` | Lowercase 64-digit BLAKE3 string | Read-only |
| `fs.glob(pattern)` | Sorted list of relative `path` values | Read-only |
| `fs.write(path, contents)` | `nil`; atomic write with parent-directory creation | Effectful |
| `fs.mkdir(path)` | `nil`; recursive directory creation | Effectful |
| `fs.copy(source, destination)` | `nil`; copies a file and creates destination parents | Effectful |
| `fs.remove(path)` | `nil`; removes a file or recursively removes a directory; missing paths are ignored | Effectful |

`contents` must be string/path text. Convert other values with `str`. `fs.copy`
is file copying, not a recursive directory-copy API, and copies original bytes
even for a `.in` source. `fs.hash` also hashes original bytes; unlike `fs.read`,
it does not hash rendered template text. The underlying hash helper returns a
deterministic missing-path marker hash for a missing path; use `fs.exists` if
existence is part of your validation.

### Globs

`*` matches within a path segment; `?` matches one non-separator character;
`**` can cross directory boundaries. `**/` also matches no intermediate directory.

```ratt
let c_files = fs.glob("src/**/*.c")
let headers = fs.glob("include/*.h")
```

Globbing considers regular, non-symlink files. It omits paths with a component
beginning with `.`. Results are sorted and expressed relative to the evaluator's
working directory. Use relative patterns; glob matching compares against those
relative paths. Bracket character classes and brace expansion are not glob
features in this implementation.

A read or glob is a query, not an automatic registration of build inputs. Add
the paths to the target's fields when execution depends on them.

### Writes in actions

With `sandbox: true`, filesystem writes must remain under declared output
directories; paths traversing symlinks are rejected. The scope is a directory
scope, not a separate permit for each declared filename. Declare important
generated files as outputs of appropriate rules so consumers can depend on
them. See [chapter 8](08-actions-and-graphs.md).

## 6.4 `path`: path manipulation

```ratt
import "path"
```

| Call | Result / semantics |
| --- | --- |
| `path.join(part, ...)` | `path`; join positional segments using the backend's path conventions |
| `path.normalize(path)` | `path`; lexically normalize `.`/`..` and separators |
| `path.absolute(path)` | `path`; resolve against the evaluator's working directory and normalize |
| `path.relative(path, base: evaluator_cwd)` | `path`; path relative to the resolved base |
| `path.dirname(path)` | `path`; containing-directory text |
| `path.basename(path)` | `str`; final filename component |
| `path.extension(path)` | `str`; extension including its dot, or empty string |
| `path.stem(path)` | `str`; basename with its final extension removed |
| `path.value(path)` | `path`; wrap text without normalization or existence checks |

All are read-only. Normalization is lexical; it is not filesystem symlink
resolution. The join operation takes positional segments, not a list argument.

```ratt
let source = path.join("src", "main.c")
assert(type(source) == "path")
assert(path.extension(source) == ".c")
assert(path.stem(source) == "main")
```

To concatenate a path into a message, call `str(source)`. To create another
filesystem path, use `path.join(source, "child")` rather than path arithmetic.

## 6.5 `proc`: processes and process environment

```ratt
import "proc"
```

| Call | Result | Phase class |
| --- | --- | --- |
| `proc.run(command, cwd: evaluator_cwd, check: true)` | Map with integer `code` and string `output` | Effectful |
| `proc.which(name)` | Absolute `path`, or an empty path when not found | Read-only |
| `proc.env(name, default: "")` | String from the process environment | Effectful |

`command` is a list of argument strings/path values. It is passed directly to
process spawning, without an implicit shell. Redirection, pipes, wildcard
expansion, and environment-assignment syntax are therefore not special inside
the list. Invoke a shell explicitly if an action genuinely needs shell syntax.

```ratt
let compiler = proc.which("cc")
assert(compiler, "C compiler is unavailable")
```

During execution or standalone evaluation:

```ratt
let result = proc.run(["python3", "tools/check.py"], check: false)
assert(result.code == 0, "the checker failed")
```

A nonzero status with `check: true` raises `E_ACTION`. Output is captured in
`result.output` and also sent to the evaluator's output callback when present,
with trailing whitespace removed for that display. The captured result retains
the process output text. The API does not expose separate stdout/stderr fields,
streaming handles, timeout arguments, or an environment-map argument.

`proc.env` reads ambient environment and is construction-phase effectful.
Use `env.get` for graph configuration. Subprocess environment behavior and
sandbox fallbacks are explained in [chapter 16](16-portability-and-automation.md).

## 6.6 `str`: text utilities

```ratt
import "str" as text
```

Aliasing avoids hiding the `str(...)` conversion built-in. Replace `text` with
`str` in the signatures below if imported without an alias.

| Call | Result |
| --- | --- |
| `text.split(value, separator: " ")` | List of string pieces separated by the supplied string |
| `text.join(values, separator: "")` | String joining each list/set value's display text |
| `text.replace(value, old, new)` | String with occurrences replaced |
| `text.lower(value)` | Lowercased string |
| `text.upper(value)` | Uppercased string |
| `text.trim(value)` | String with surrounding whitespace removed |
| `text.contains(value, needle)` | Bool |
| `text.starts_with(value, prefix)` | Bool |
| `text.ends_with(value, suffix)` | Bool |
| `text.format(template, values)` | String with map-field placeholders replaced |

All calls are read-only. `split` uses the supplied separator string; it is not
a regular-expression API. `join` accepts a list/set and applies display
conversion to its entries.

```ratt
import "str" as text
let fields = {name: "app", version: "1.0.0"}
assert(text.format("{name}-{version}", fields) == "app-1.0.0")
```

Formatting is literal replacement of `{key}`, in sorted key order. Missing
placeholders remain unchanged. Replacement values are not escaped for any
destination language, and inserted text can participate in later replacements.
This function is separate from the `.in` preprocessor's `@{expression}` syntax.

## 6.7 `env`: configuration access

```ratt
import "env"
```

| Call | Result |
| --- | --- |
| `env.get(key, default: nil)` | Configured value or the supplied fallback |
| `env.has(key)` | Bool indicating whether the flattened key exists |

Both are read-only. Nested configuration keys use dotted strings such as
`"toolchain.c"`. Returned collections are copied recursively, so mutating them
does not alter the configuration:

```ratt
let mirrors = env.get("pkg.mirrors", [])
mirrors.append("https://mirror.example.org")
```

This changes only the local list. To change actual settings, edit the user
configuration before loading a graph. Configuration is captured with actions;
see [chapter 9](09-configuration.md).

## 6.8 `toolchain`: discovery and platform fields

```ratt
import "toolchain"
```

`toolchain.discover(language)` reads `toolchain.<language>` from configuration,
locates the executable, queries `--version`, and returns:

| Field | Type | Meaning |
| --- | --- | --- |
| `command` | `str` | Located compiler path |
| `version` | `str` | Trimmed version-query output |
| `fingerprint` | `str` | BLAKE3 combination of path, executable hash, and version output |

Languages used by native target lowering are `c`, `cxx`, and `d`. Missing
compilers raise `E_TARGET`. Discovery is a designated read-only construction
query; it does not grant arbitrary construction-time `proc.run` calls.

`toolchain.flags(mode: "debug")` returns `["-O2"]` for the literal mode
`"release"`, and `["-g"]` for other modes. It is a small convenience API, not a
comprehensive translation of flags for every compiler.

| Field | POSIX | macOS | Windows |
| --- | --- | --- | --- |
| `platform` | `"posix"` | `"macos"` | `"win32"` |
| `executable_suffix` | `""` | `""` | `".exe"` |
| `shared_suffix` | `".so"` | `".dylib"` | `".dll"` |
| `runtime_library` | `"librattpack.so"` | `"librattpack.dylib"` | `"rattpack.dll"` |

## 6.9 `target`: build declarations

The module is installed by the specification loader and is available in a
project context:

```ratt
import "target"
```

- `target.executable(...)` returns a `target` handle.
- `target.library(...)` returns a `target` handle.
- `target.rule(...)` returns a `rule` handle.

The globally bound `rule(...)` also declares a custom rule. Before importing
the module, a global `target(...)` declaration function is available, but the
module-specific forms are clearer. See [chapter 7](07-projects-and-targets.md)
for the complete field reference.

Importing `target` in a plain standalone script raises `E_IMPORT` because no
project declaration context has been installed.

## 6.10 `pkg`: already-fetched dependencies

In a build spec:

```ratt
import "pkg"
let library = pkg.get("library")
```

`pkg.get(name)` reads the context's `Rattpkg.lock`, locates the named cached tree,
and returns a `pkg` handle with `path` (a path value) and `version` (a string).
It raises `E_PACKAGE` for a missing lock entry or missing cache directory.

The lookup does not fetch dependencies or re-hash the tree. Use `rattpkg fetch`
and `rattpkg verify` separately. Resolve package handles during construction
and capture their paths for execution. Member-specific lock lookup is explained
in [chapter 11](11-modules-and-monorepos.md).

## 6.11 `log`: messages

```ratt
import "log"
```

`log.info(message)`, `log.warn(message)`, `log.error(message)`, and
`log.debug(message)` send `level: message` text to the evaluator's output
callback and return `nil`. They are permitted during construction.

These are message-emission functions, not coded diagnostics. `log.error` does
not abort evaluation, and `log.warn` is not promoted by `--warnings-as-errors`.
Use `assert` when a script must fail a condition. The spec loader does not
install a general stdout callback during construction, so informational script
output is most useful in standalone execution or action bodies.

## 6.12 `collections`: pure Rattscript helpers

The module is implemented in embedded Rattscript rather than a native plugin:

```ratt
import "collections"
let doubled = collections.map([1, 2, 3], fn(x) { return x * 2 })
let evens = collections.filter(doubled, fn(x) { return x % 2 == 0 })
let sum = collections.fold(evens, 0, fn(a, b) { return a + b })
assert(sum == 12)
```

| Call | Behavior |
| --- | --- |
| `collections.map(values: list, transform: fn)` | New list of transformation results |
| `collections.filter(values: list, predicate: fn)` | New list of entries whose predicate result is true-like |
| `collections.fold(values: list, initial, combine: fn)` | Left fold of the sequence |

Callbacks execute in the caller's evaluation phase. A collection helper used
during construction cannot make an effectful callback permissible.
