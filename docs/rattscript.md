# Rattscript reference

The evaluator walks AST nodes directly and caches parsed module ASTs. Imports
are evaluated once per evaluator and cyclic imports are rejected.

## Syntax

```ratt
let number: int = 42
let values = [1, 2, 3]
let settings = {debug: true, "output-dir": "build"}
let unique = set([1, 1, 2])

fn add(a: int, b: int = 1) -> int { return a + b }
let closure = fn(value) { return add(value, b: number) }

for value in values {
  if value != 2 { print(closure(value)) }
}
```

`#` and `//` start line comments. Strings support single/double quotes and
`\n`, `\r`, `\t`, `\b`, `\f`, `\/`, `\uXXXX`, escaped quotes, and backslashes.
Unicode text may also be written directly as UTF-8. Collections support indexing;
negative list/string indices count from the end. Maps also support member access.
Map iteration is sorted by key. Lists are mutable references, with `.append()`
and `.length`. Sets remove duplicate values. `sorted`, `keys`, `range`, `len`,
`type`, `assert`, `print`, `int`, `float`, and string conversion are built-ins.

Operators, low to high precedence: `or`/`||`, `and`/`&&`, equality, comparison and
`in`, half-open `..` ranges, `+`/`-`, `*`/`/`/`%`, and unary `!`/`not`/`-`/`+`.
Boolean operators short-circuit and return their selected operand. Integer
arithmetic is checked for overflow. `+=`, `-=`, `*=`, and `/=` assign in place.
In the current release, `break`/`continue` work in `while` loops but escape
`for`/`foreach` loops as `E_RUNTIME`; use guarded iteration there. See the
[manual's control-flow reference](../manual/05-rattscript.md#58-control-flow)
and [recorded issue](issues/spec-drift-for-loop-control.md).
An expression can continue on the next line after an operator, and grouped
expressions, collections, and argument lists can span multiple lines.

## Modules

```ratt
import "fs"
import "./helpers.ratt" as helpers
```

Module bindings are namespaced. Local modules export their top-level bindings.
Modules can shadow built-in names (for example, `import "str"` replaces the
string-conversion binding in that scope).

| Module | Functions / fields |
| --- | --- |
| `fs` | `exists`, `is_file`, `is_dir`, `read`, sorted `glob`, BLAKE3 `hash`, atomic `write`, `mkdir`, `copy`, `remove` |
| `path` | `join`, `normalize`, `absolute`, `relative`, `dirname`, `basename`, `extension`, `stem`, `value` |
| `proc` | `run` (argv list, optional cwd/check; returns code/output), `which`, process `env` |
| `str` | `split`, `join`, `replace`, `lower`, `upper`, `trim`, `contains`, `starts_with`, `ends_with`, map-based `format` |
| `toolchain` | `discover` (command/version/fingerprint), `flags`, platform and output suffix fields |
| `target` | `executable`, `library`, `rule` (build-spec context) |
| `pkg` | `get` (already-fetched dependency from the lock; build-spec context) |
| `env` | read-only configuration `get`, `has` |
| `log` | `info`, `warn`, `error`, `debug` |
| `collections` | pure Rattscript `map`, `filter`, `fold` |

Construction-phase `proc.run`, process environment reads, and filesystem writes
raise `E_PHASE_VIOLATION`, including calls through aliases and closures. Action
blocks capture shared collection identities, function closures, and native
bindings in a deterministic, serializable object graph.
