# 6. Modules and standard library

[Previous: Rattscript](05-rattscript.md) · [Contents](README.md) · [Next: Targets](07-projects-and-targets.md)

This chapter is the API reference. For complete programs using the expanded
library, continue with [collection pipelines](20-collection-pipelines.md),
[structured data](21-structured-data-and-text.md),
[numeric reports](22-numeric-analysis.md), and
[release workflows](23-versioned-release-workflows.md).

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
| `proc.env(name, default: "")` | String from the captured action environment, or ambient environment in standalone/unsandboxed execution | Effectful |

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

`proc.env` is construction-phase effectful. In a normal sandboxed action it
reads the action's captured environment; in standalone or unsandboxed execution
it reads the ambient process environment. Use `env.get` for graph configuration
and a target's `env:` map for explicit process values. Environment defaults and
subprocess behavior are explained in [chapter 16](16-portability-and-automation.md)
and [chapter 25](25-hermetic-builds.md).

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

## 6.13 `list`: sequences

```ratt
import "list" as sequence
assert(sequence.sort([10, 2, 1]) == [1, 2, 10])
assert(sequence.chunks([1, 2, 3], 2) == [[1, 2], [3]])
```

These functions take lists and return fresh lists. Copies are shallow: nested
values retain their identities. The input list is not modified.

| Call | Behavior |
| --- | --- |
| `list.copy(values: list)` | Shallow copy |
| `list.slice(values: list, start: int = 0, stop = nil)` | Half-open slice; negative bounds count from the end, out-of-range bounds are clipped, `nil` stop means the list length |
| `list.reverse(values: list)` | Reverse element order |
| `list.unique(values: list)` | First occurrence of each structurally equal value, in input order |
| `list.flatten(values: list)` | Flatten exactly one level of nested lists |
| `list.chunks(values: list, size: int)` | Consecutive chunks; the final chunk may be shorter; size must be positive |
| `list.sort(values: list, less: fn = fn(a, b) { return a < b })` | Stable merge sort using a strict less-than predicate |

Unlike the `sorted` built-in's display-text ordering, `list.sort` uses numeric
ordering for numbers and lexical ordering for strings by default. For records:

```ratt
let ordered = sequence.sort([{priority: 10}, {priority: 2}],
    less: fn(a, b) { return a.priority < b.priority })
assert(ordered[0].priority == 2)
```

Equal elements retain their original relative order. Sorting takes
O(n log n) comparisons. An empty slice or a start at/after stop returns `[]`.
Invalid element types or non-integer slice bounds raise `E_TYPE`; a nonpositive
chunk size raises `E_RUNTIME`.

## 6.14 `dict`: string-keyed maps

```ratt
import "dict"
let settings = dict.merge({mode: "debug", jobs: 1}, {jobs: 4})
assert(dict.get(settings, "jobs") == 4)
assert(dict.get(settings, "missing", default: false) == false)
```

| Call | Behavior |
| --- | --- |
| `dict.get(values: map, key: str, default = nil)` | Lookup with a fallback only for a missing key; stored `nil` is preserved |
| `dict.values(entries: map)` | Values in sorted key order |
| `dict.items(entries: map)` | `[key, value]` pairs in sorted key order |
| `dict.from_items(entries: list)` | Map from two-element pairs with string keys; the last repeated key wins |
| `dict.merge(left: map, right: map)` | Shallow merge; right-hand keys win |
| `dict.pick(entries: map, selected: list)` | Keep selected string keys, ignoring missing keys |
| `dict.omit(entries: map, excluded: list)` | Remove listed keys from a shallow copy |
| `dict.map_values(entries: map, transform: fn)` | Apply a unary callback to each value in sorted key order |

Returned containers are fresh and their values are shallow references.
`from_items` raises `E_RUNTIME` for pairs of the wrong length and `E_TYPE` for
non-list pairs or non-string keys.

## 6.15 `sets`: set algebra

```ratt
import "sets"
assert(sets.union([1, 1, 2], set([2, 3])) == set([1, 2, 3]))
assert(sets.difference([1, 2], [2]) == set([1]))
```

Both operands may be lists or sets. Structural equality controls membership;
operands are not modified. Set results retain first-seen element order for
iteration, while set display text sorts element representations.

| Call | Result |
| --- | --- |
| `sets.union(left, right)` | Set of elements in either operand |
| `sets.intersection(left, right)` | Set of elements in both operands |
| `sets.difference(left, right)` | Set of left elements absent from right |
| `sets.symmetric_difference(left, right)` | Set of elements in exactly one operand |
| `sets.is_subset(left, right)` | Bool; all left elements occur in right |
| `sets.is_superset(left, right)` | Bool; all right elements occur in left |
| `sets.is_disjoint(left, right)` | Bool; operands have no common elements |

The empty set is a subset of every set and is disjoint from every set.

## 6.16 `iter`: eager iteration

```ratt
import "iter"
assert(iter.zip(["a", "b", "c"], [1, 2]) == [["a", 1], ["b", 2]])
assert(iter.scan([1, 2, 3], 0, fn(a, b) { return a + b }) == [0, 1, 3, 6])
```

All sequence arguments are lists. Operations produce eager results; container
elements are shallow references.

| Call | Behavior |
| --- | --- |
| `iter.take(values, count: int)` | First count elements, clipped to the list length |
| `iter.drop(values, count: int)` | Elements after the first count |
| `iter.take_while(values, predicate: fn)` | Prefix until the first false-like callback result |
| `iter.drop_while(values, predicate: fn)` | Suffix starting at the first false-like callback result |
| `iter.enumerate(values, start: int = 0)` | `[index, value]` pairs |
| `iter.zip(left, right)` | Pairs up to the shorter input's length |
| `iter.product(left, right)` | Cartesian-product pairs, in left-major order |
| `iter.scan(values, initial, combine: fn)` | Initial value followed by every left-fold accumulator |
| `iter.all(values, predicate: fn)` | Short-circuit on the first false-like result; true for an empty list |
| `iter.any(values, predicate: fn)` | Short-circuit on the first true-like result; false for an empty list |
| `iter.find(values, predicate: fn, default = nil)` | First matching element, or default |
| `iter.count(values, predicate: fn)` | Number of true-like callback results |

Negative take/drop counts raise `E_RUNTIME`. Callbacks run in input order and
retain phase restrictions, including callbacks wrapped by `functional`.

## 6.17 `functional`: function composition

```ratt
import "functional" as functions
let transform = functions.pipe([
    fn(x) { return x + 1 },
    fn(x) { return x * 2 }
])
assert(transform(3) == 8)
```

| Call | Behavior |
| --- | --- |
| `functional.identity(value)` | Return value unchanged |
| `functional.constant(value)` | Unary function ignoring its argument and returning the captured value |
| `functional.compose(outer: fn, inner: fn)` | Unary function evaluating `outer(inner(value))` |
| `functional.pipe(transforms: list)` | Unary function applying callbacks left-to-right; empty list is identity |
| `functional.negate(predicate: fn)` | Unary function negating the callback's truth value |
| `functional.bind_first(combine: fn, first)` | Unary function calling binary `combine(first, second)` |
| `functional.repeat(transform: fn, count: int)` | Unary function applying transform count times; zero is identity |

`pipe` shallow-copies and validates the callback list when created, so later
changes to that list do not change the pipeline. Captured values and callbacks
retain their identities and can be serialized with action closures. A negative
repeat count raises `E_RUNTIME`.

## 6.18 `math`: numeric helpers

```ratt
import "math"
assert(math.pow(2, 10) == 1024)
assert(math.pow(2, -4) == 0.0625)
assert(math.gcd(54, 24) == 6)
```

`math.pi` and `math.e` are floating-point constants. Number-taking parameters
accept both integers and floats; these annotations do not coerce integers.

| Call | Behavior |
| --- | --- |
| `math.abs(value)` | Absolute value, preserving integer/float kind |
| `math.sign(value)` | Integer -1, 0, or 1 |
| `math.min(left, right)`, `math.max(left, right)` | Smaller/larger argument |
| `math.clamp(value, lower, upper)` | Bound value to an inclusive interval; lower must not exceed upper |
| `math.pow(base, exponent: int)` | Exponentiation by squaring; negative exponents produce floats; zero exponent returns 1 |
| `math.gcd(left: int, right: int)` | Nonnegative greatest common divisor; `gcd(0, 0)` is zero |
| `math.lcm(left: int, right: int)` | Nonnegative least common multiple; zero if either argument is zero |
| `math.sqrt(value)` | Float square root |
| `math.floor(value)`, `math.ceil(value)` | Float integral value, rounded down/up |
| `math.round(value)` | Float integral value, nearest with ties away from zero |
| `math.log(value)`, `math.exp(value)` | Natural logarithm/exponential |
| `math.sin(value)`, `math.cos(value)`, `math.tan(value)` | Float trigonometric result, with arguments in radians |
| `math.is_finite(value)` | Bool; false for NaN or infinity |

Integer operations preserve checked arithmetic. An unrepresentable absolute
value, power, or LCM raises `E_RUNTIME`. Native floating-point functions from
`sqrt` through `tan` require finite inputs and finite results; invalid domains
(such as negative square roots or logarithms of nonpositive numbers) raise
`E_RUNTIME`.

## 6.19 `stats`: descriptive statistics

```ratt
import "stats"
assert(stats.median([10, 2, 3]) == 3)
assert(stats.variance([1, 2, 3], sample: true) == 1)
```

All functions take numeric lists and leave input order unchanged.

| Call | Behavior |
| --- | --- |
| `stats.sum(values: list)` | Checked sum; empty input returns integer zero |
| `stats.mean(values: list)` | Float arithmetic mean; requires at least one value |
| `stats.quantile(values: list, q)` | Float linear interpolation at sorted position `(n - 1) * q`, with `0 <= q <= 1` |
| `stats.median(values: list)` | Quantile at 0.5 |
| `stats.variance(values: list, sample: bool = false)` | Float variance using Welford's recurrence; divides by n, or n - 1 for sample variance |
| `stats.stdev(values: list, sample: bool = false)` | Float square root of variance |

Population variance requires at least one value; sample variance requires two.
Empty/undersized inputs or out-of-range quantiles raise `E_RUNTIME`. Wrong
element types raise `E_TYPE`.

## 6.20 `json`: structured data

```ratt
import "json"
let manifest = json.parse('{"name":"app","versions":["1.0.0"]}')
assert(json.get(manifest, ["versions", 0]) == "1.0.0")
assert(json.stringify({z: 2, a: 1}) == '{"a":1,"z":2}')
```

| Call | Behavior |
| --- | --- |
| `json.parse(value: str)` | Strict RFC 8259 parsing; returns maps/lists, strings, numbers, bools, or `nil` for null |
| `json.stringify(value, pretty: bool = false)` | Deterministic JSON with recursively sorted object keys; pretty mode uses two-space indentation |
| `json.get(value, path: list, default = nil)` | Traverse string object keys/nonnegative integer array indices; return default for missing/incompatible steps |

Encoding accepts `nil`, bools, integers, finite floats, strings, paths (encoded
as strings), lists, and maps. Other kinds raise `E_TYPE`. Malformed input,
non-finite numbers, integers outside Rattscript's signed 64-bit range, cycles,
and nesting beyond 256 levels raise `E_RUNTIME`. Shared acyclic subcontainers
are encoded normally. Unicode text and escapes, including surrogate pairs, are
supported. A present JSON null remains `nil` even when `get` has a fallback.

## 6.21 `regex`: regular expressions

```ratt
import "regex" as re
assert(re.find("version=1.2", "([0-9]+)\\.([0-9]+)") == ["1.2", "1", "2"])
assert(re.replace("v12", "([0-9]+)", "[$1]") == "v[12]")
```

Patterns use D Phobos regular-expression syntax. Rattscript string literals
need doubled backslashes to pass a literal backslash into the pattern.

| Call | Behavior |
| --- | --- |
| `regex.test(value: str, pattern: str, flags: str = "")` | Bool indicating any match |
| `regex.find(value: str, pattern: str, flags: str = "")` | First match's capture list, or `nil` |
| `regex.find_all(value: str, pattern: str, flags: str = "")` | List of non-overlapping matches' capture lists |
| `regex.replace(value: str, pattern: str, replacement: str, flags: str = "")` | Replace every match; `$1`, `$2`, etc. refer to captures |
| `regex.split(value: str, pattern: str, flags: str = "")` | List of pieces separated by matches |
| `regex.escape(value: str)` | Quote regular-expression metacharacters for literal matching |

Capture zero is the full match; subsequent entries are parenthesized groups.
Unmatched optional groups are empty strings. Flags include `i` (ignore case),
`m` (multiline), `s` (dot matches newlines), and `x` (extended pattern syntax).
Invalid patterns or flags raise `E_RUNTIME`.

## 6.22 `base64`: text/byte encoding

```ratt
import "base64"
assert(base64.encode("ratt") == "cmF0dA==")
assert(base64.decode("cmF0dA==") == "ratt")
```

`base64.encode(value: str, url_safe: bool = false)` encodes the string's bytes.
`base64.decode(value: str, url_safe: bool = false)` returns decoded bytes in a
string. This preserves UTF-8, embedded NULs, and arbitrary byte data.

Both use RFC 4648 padding. URL-safe mode selects `-` and `_` instead of `+`
and `/`. Decoding requires canonical padded input: invalid characters, missing
or excess padding, whitespace, or nonzero unused padding bits raise
`E_RUNTIME`. Empty strings round-trip as empty strings.

## 6.23 `semver`: semantic versions

```ratt
import "semver"
assert(semver.compare("1.0.0-alpha.2", "1.0.0-alpha.10") == -1)
assert(semver.compare("1.0.0+first", "1.0.0+second") == 0)
assert(semver.bump("1.2.3-beta", "minor") == "1.3.0")
```

| Call | Behavior |
| --- | --- |
| `semver.valid(value: str)` | Bool checking a complete `major.minor.patch[-prerelease][+build]` version |
| `semver.parse(value: str)` | Map with integer `major`, `minor`, `patch`, and string `prerelease`, `build` (empty when absent) |
| `semver.compare(left: str, right: str)` | -1, 0, or 1 according to SemVer 2.0 precedence; build metadata is ignored |
| `semver.sort(versions: list)` | Stable ascending version order; validates every version |
| `semver.bump(value: str, part: str = "patch")` | Increment major/minor/patch, reset lower components, and discard prerelease/build suffixes |

Components must fit signed 64-bit integers. Numeric prerelease identifiers have
no size limit and compare numerically by digit length and lexical order.
Numeric identifiers precede nonnumeric ones, and releases follow prereleases.
Leading zeroes in numeric version/prerelease components, shortened versions,
`v` prefixes, and empty identifiers are rejected. Build metadata permits leading
zeroes. Invalid versions, unknown bump parts, or increment overflow raise
`E_RUNTIME`; `valid` instead returns false for invalid strings.

All modules in §§6.13–6.23 are embedded in `librattpack` from `stdlib/*.ratt`.
Their functions are deterministic and permitted during graph construction.
Native primitives are registered for action restoration; returned functions
and module helpers work after graph export/import as well as standalone.
