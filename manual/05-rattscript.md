# 5. The Rattscript language

[Previous: Command line](04-command-line.md) · [Contents](README.md) · [Next: Standard library](06-standard-library.md)

Rattscript is dynamically typed and tree-walked. The same language is used for
build specifications, package manifests, templates, reusable modules, and
standalone programs. The host context determines which functions are available
and which effects are permitted.

## 5.1 Source layout and lexical rules

Identifiers use ASCII letters, digits, and underscores, with a letter or
underscore first. Names are case-sensitive. `#` and `//` introduce comments
extending to the end of the line.

```ratt
# A complete standalone script.
let greeting = "hello"
print(greeting) // A second comment style.
```

Newlines or semicolons normally separate statements. Blocks use braces. Lists,
map literals, function parameter lists, call arguments, and parenthesized
expressions can span lines. An expression can continue after a binary operator:

```ratt
let values = [1, 2] +
  [3, 4]
let answer = (
  6 *
    7
)
print(values, answer)
```

Place the operator at the end of the preceding line. There is no backslash
continuation convention. Comma-separated collections and argument lists allow
a trailing comma.

## 5.2 Values and truthiness

| Type name | Meaning | Example |
| --- | --- | --- |
| `nil` | Absence of a value | `nil` |
| `bool` | Boolean | `true`, `false` |
| `int` | Signed 64-bit integer | `42`, `-7` |
| `float` | Double-precision floating-point value | `1.5`, `2e3` |
| `str` | UTF-8 string storage | `"text"` |
| `path` | A distinguished path value accepted by path/file APIs | `path.value("src/main.c")` after importing `path` |
| `list` | Ordered mutable collection | `[1, "two"]` |
| `map` | Mutable map with string keys | `{name: "app", jobs: 4}` |
| `set` | Unique collection constructed from a list/set | `set([1, 1, 2])` |
| `fn` | Native or user-defined callable | `fn(x) { return x + 1 }` |
| `target` | Compiled/general target handle | Result of `target.executable(...)` |
| `rule` | Custom rule handle | Result of `rule(...)` |
| `pkg` | Package handle | Result of `pkg.get(...)` |

Conditions accept any value. False-like values are `nil`, `false`, numeric zero,
empty strings, empty paths, and empty collections. Functions and target/rule/
package handles are true-like. A path's truthiness depends on whether its stored
text is empty, not on whether the filesystem entry exists.

The `type(value)` built-in returns the type names above. `any` is an annotation
meaning unrestricted values; it is not a separate runtime value type.

## 5.3 Numeric values

Integers range from `-9223372036854775808` to `9223372036854775807`. Literal
overflow is a parse error. Addition, subtraction, multiplication, negation, and
integer division/remainder check relevant overflow cases and report
`E_RUNTIME`.

```ratt
let minimum: int = -9223372036854775808
let maximum: int = 9223372036854775807
assert(maximum > maximum - 1)
print(7 / 2, 7 % 2)  # 3 1
print(7 / 2.0)       # 3.5
```

Integer division truncates toward zero. If an arithmetic operand is a float,
numeric arithmetic uses floating-point values. Division or remainder by zero
is an error for both numeric types.

Integer-to-integer comparisons are exact. Comparisons or equality between an
integer and a float convert numeric values to double precision; sufficiently
large integers can lose precision in that mixed comparison. Keep values as
integers when exact large-integer identities matter.

Literals are decimal, with optional fractional parts and decimal exponents.
There are no hexadecimal, binary, or digit-separator literal forms.

## 5.4 Strings

Single and double quotes have the same escape processing:

```ratt
let line = "first\nsecond"
let quoted = 'a "quoted" word'
let windows_path = "C:\\work\\project"
let unicode_text = "caf\u00e9"
```

Recognized escapes are `\n`, `\r`, `\t`, `\b`, `\f`, `\\`, `\"`, `\'`, `\/`,
and `\uXXXX`. Unicode surrogate escape values are rejected; write supplementary
Unicode characters directly as UTF-8. Unknown escapes raise `E_PARSE`.

String concatenation uses `+` when both operands are strings. Convert other
values explicitly with `str(...)`. Strings do not perform automatic `${...}`
or `@{...}` interpolation during ordinary `.ratt` evaluation; `@{...}` belongs
to the `.in` template preprocessor.

`len(text)` and indexed string access use **UTF-8 bytes**. For example, `len("é")`
is 2. In contrast, `for character in text` iterates Unicode code points as
individual strings. Indexed access is most convenient for ASCII text; indexing
one byte of a multibyte sequence need not produce a valid Unicode character.

## 5.5 Bindings, assignment, and scopes

```ratt
let count: int = 0
count += 1
var label = "first"
label = "second"
```

In this release, `let`, `var`, and `const` are accepted spellings of the same
binding operation. They do not provide different mutability guarantees. A
binding may be reassigned, provided any annotation remains satisfied.

Assignment supports `=`, `+=`, `-=`, `*=`, and `/=`. Compound assignment performs
the corresponding binary operation and writes the result back. Assignable
locations include existing bindings, list elements, and map keys/members.

```ratt
let values = [1, 2]
values[-1] = 7
let settings = {mode: "debug"}
settings.mode = "release"
settings["jobs"] = 4
```

List assignment must address an existing element. Map assignment can create a
new key. Assigning an undefined bare binding is `E_NAME`.

Functions, `if` branches, and loop iterations create child environments.
Assignments search outward for an existing binding; a new local declaration
does not replace an outer binding. Duplicate declarations in one environment
are errors. A bare brace block and the `deps`/`monorepo` grouping sections execute
in their surrounding environment rather than creating a new lexical scope.

## 5.6 Lists, maps, and sets

Lists preserve order. Assignment shares the list object:

```ratt
let original = ["a"]
let alias = original
alias.append("b")
assert(len(original) == 2)
```

`append(value)` returns the list itself. `list + list` creates a new list
container containing the two sequences; nested collection objects remain
shared. `.length` is also available on collections and strings.

Indices are zero-based. Negative indices count backward from the end. Out-of-
range reads or writes raise `E_RUNTIME`. There is no slice syntax.

Map literal keys are quoted strings or identifier spellings:

```ratt
let table = {debug: true, "output-dir": "build"}
assert(table.debug)
print(table["output-dir"])
```

An identifier key in a literal is its spelling, not an evaluated variable.
Missing key/member reads raise `E_NAME`. Map iteration and `keys(map)` use sorted
key order. If a map has a key named `length`, member access returns that key;
`len(map)` still reports the number of entries.

`set(values)` keeps the first occurrence of each equal value. Sets support
membership, length, indexing, and iteration, but have no shipped add/remove
methods. Their iteration preserves the unique values' construction order;
their displayed representation sorts the values' text representations.

Equality compares list elements in order, map keys and values structurally,
and set members without regard to order. Function equality is object identity;
target/rule/package handle equality uses their names within the same value kind.

## 5.7 Operators

Precedence increases down this table. Binary operators at the same level
associate left-to-right.

| Level | Operators | Meaning |
| --- | --- | --- |
| 1 | `or`, `\|\|` | Short-circuit selection of a true-like operand |
| 2 | `and`, `&&` | Short-circuit selection requiring a true-like left operand |
| 3 | `==`, `!=` | Equality and inequality |
| 4 | `<`, `>`, `<=`, `>=`, `in` | Ordering or membership |
| 5 | `..` | Eager, ascending, half-open integer range |
| 6 | `+`, `-` | Numeric arithmetic; `+` also concatenates strings/lists |
| 7 | `*`, `/`, `%` | Numeric multiplication, division, remainder |
| Unary | `!`, `not`, `-`, `+` | Logical negation, numeric negation/validation |
| Postfix | Calls, `.member`, `[index]` | Function calls and access |

Boolean operators return an operand rather than coercing the result to a bool:

```ratt
assert(("" or "fallback") == "fallback")
assert((0 and "unused") == 0)
assert(not nil)
assert("build" in "build/output")
assert("mode" in {mode: "debug"})
assert(2 in [1, 2, 3])
```

Membership tests map keys, string substrings, or list/set values. Strings support
lexicographic ordering. Paths are distinct values: use the `path` module for
joining/normalizing them, and `str(path_value)` when textual comparison or
concatenation is intended.

`0 .. 3` creates `[0, 1, 2]`. A descending `..` range is empty. Use `range` with a
negative step for descending sequences. Ranges are materialized lists, so their
memory usage grows with the number of elements.

## 5.8 Control flow

```ratt
let total = 0
for value in range(5) {
  if value != 2 { total += value }
}
assert(total == 8)

let remaining = 3
while remaining > 0 {
  remaining -= 1
  if remaining == 1 { break }
}
```

`if` supports `else` and `else if`. `while` reevaluates its condition each time.
`for` and its synonym `foreach` bind one variable per iteration. Map loops bind
keys; string loops bind Unicode-character strings; list/set loops bind values.
List/set iteration uses a copy of the sequence being iterated, so appending to
the original does not extend that loop's iteration sequence.

`break` and `continue` work as loop control in `while` loops. `return` leaves a
function. Using loop control outside a loop or `return` outside a function is an
execution error.

**Current `for`/`foreach` limitation:** although the parser accepts `break` and
`continue` in these loops, the 0.1.0 evaluator currently reports
`E_RUNTIME: loop control outside a loop` when either is reached. Use a condition
around work to skip an iteration, as above, or use `while` when explicit early
termination/continuation is required. The reproduction is recorded in
[`spec-drift: for-loop control escapes the evaluator`](../docs/issues/spec-drift-for-loop-control.md).

There are no user-language exception handlers, switch statements, comprehensions,
classes, or pattern-matching constructs in this release.

## 5.9 Functions and closures

Named functions support parameter annotations, defaults, and a return annotation:

```ratt
fn add(a: int, b: int = 1) -> int {
  return a + b
}
assert(add(41) == 42)
assert(add(b: 2, a: 40) == 42)

fn factorial(n: int) -> int {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}
assert(factorial(5) == 120)
```

User-function calls reject unknown named arguments, duplicated parameter
supplies, missing required arguments, and excess positional arguments. Defaults
are evaluated at call time in the function's call environment, after earlier
parameters have been bound. Prefer positional arguments before named ones.

Anonymous functions use `fn(parameters) { body }` and can annotate parameters;
the anonymous form has no `->` return-annotation syntax in this release.

```ratt
fn counter(start: int) -> fn {
  let current = start
  return fn() {
    current += 1
    return current
  }
}
let next = counter(40)
assert(next() == 41)
assert(next() == 42)
```

Closures capture lexical environments, including shared mutable collections.
Named functions are available after their declaration executes. A function
without an executed `return value` returns `nil`; an incompatible declared
return type then fails at the call boundary.

## 5.10 Optional annotations and linting

Valid annotation names are `any`, `nil`, `bool`, `int`, `float`, `str`, `path`,
`list`, `map`, `set`, `fn`, `target`, `rule`, and `pkg`.

```ratt
let jobs: int = 4
fn description(name: str) -> str { return "target " + name }
```

Runtime binding initialization, reassignment, parameter binding, and named-
function returns enforce annotations. `float` annotations accept integer
values, but do not automatically rewrite the stored integer to a float.
Annotations describe collection kinds, not element types: there is no
`list[int]` annotation syntax.

`rattsc --lint FILE` checks statically inferable mismatches, including those in
uncalled functions and branches that may never execute. It recursively checks
statically imported source modules. Dynamic member access and many native
functions have an unknown inferred type, so passing lint is not proof that
every runtime operation is well-typed. Lint also does not execute a build's
identity, dependency, or output validation.

## 5.11 Built-in function reference

These functions need no import.

| Function | Behavior |
| --- | --- |
| `print(value, ...)` | Print positional values separated by one space; returns `nil` |
| `assert(condition, message: "assertion failed")` | Raise `E_RUNTIME` when the condition is false-like |
| `len(value)` | Number of collection entries or string/path bytes |
| `type(value)` | Runtime type name |
| `str(value)` | Human-readable textual representation |
| `int(value)` | Return an int unchanged, cast a float, or parse string/path text as an integer |
| `float(value)` | Convert numeric values to double precision or parse string/path text |
| `set(values: [])` | Construct a unique collection from a list/set |
| `range(end)` | Eager list from zero to, but excluding, `end` |
| `range(start, end, step: 1)` | Eager list using a nonzero positive/negative step |
| `sorted(values)` | New list sorted lexicographically by each value's `str` representation |
| `keys(map)` | New list of sorted string keys |

`sorted` is textual, not numeric: `sorted([2, 10, 1])` is `[1, 10, 2]`.
`str` is display formatting rather than a lossless Rattscript serializer; strings
inside displayed collections are not quoted or escaped.

Native functions use their documented parameter names. Importing the standard
module `str` binds a map named `str` in the current scope and shadows the
conversion built-in there. Use `import "str" as text` if both are needed.
