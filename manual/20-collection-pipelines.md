# 20. Collection pipelines

[Previous: Recipes](19-recipes.md) · [Contents](README.md) · [Next: Structured data and text](21-structured-data-and-text.md)

The expanded collection library turns ordinary Rattscript values into reusable
data-processing steps. This chapter progresses from individual containers to a
complete build-plan generator. Unless labeled `Rattspec`, each Rattscript block
is an independent standalone program: save it as `example.ratt` and run
`rattsc example.ratt`.

## 20.1 Choose the operation by its contract

| Need | Module | Important property |
| --- | --- | --- |
| Map/filter/fold a sequence | `collections` | Callbacks run in input order |
| Slice, chunk, deduplicate, or sort a list | `list` | Returns a fresh, shallow container |
| Look up or reshape string-keyed records | `dict` | Map traversal is sorted by key |
| Compare membership between groups | `sets` | Structural equality determines membership |
| Pair, enumerate, search, or scan sequences | `iter` | Results are eager; searches can short-circuit |
| Combine unary transformations | `functional` | Captured callbacks retain phase restrictions |

Signatures and defaults are listed in [chapter 6](06-standard-library.md).
The `list` module does not replace the built-in `list` value kind, and `sets`
does not hide the built-in `set(...)` conversion.

## 20.2 Slice and sort without changing the source list

```ratt
import "list" as sequence

let sizes = [10, 2, 8, 2]
assert(sequence.slice(sizes, -3, -1) == [2, 8])
assert(sequence.unique(sizes) == [10, 2, 8])
assert(sequence.chunks(sizes, 3) == [[10, 2, 8], [2]])
assert(sequence.sort(sizes) == [2, 2, 8, 10])
assert(sizes == [10, 2, 8, 2])
print(sequence.reverse(sizes))
```

`slice` is half-open. Negative bounds count from the end, and bounds outside the
list are clipped. `chunks` accepts a positive size and keeps a short final chunk.
`unique` keeps the first occurrence rather than sorting the result.

The built-in `sorted` compares display text; `list.sort` compares values with
`<` by default. This matters for numeric values such as 2 and 10. A custom
predicate can order records:

```ratt
import "list" as sequence

let records = [
  {priority: 2, name: "first"},
  {priority: 1, name: "urgent"},
  {priority: 2, name: "second"}
]
let ordered = sequence.sort(records, fn(a, b) { return a.priority < b.priority })
assert(ordered[0].name == "urgent")
assert(ordered[1].name == "first" and ordered[2].name == "second")
```

The sort is stable: entries equivalent under the predicate retain their relative
order. The predicate should implement a strict less-than relation.

Fresh containers are shallow. If an element is itself a map or list, the source
and result still refer to the same nested object:

```ratt
import "list" as sequence

let source = [{name: "before"}]
let copied = sequence.copy(source)
copied.append({name: "extra"})
assert(len(source) == 1)
copied[0].name = "after"
assert(source[0].name == "after")
```

## 20.3 Merge and reshape records

```ratt
import "dict"

let defaults = {mode: "debug", jobs: 1, note: nil}
let chosen = dict.merge(defaults, {mode: "release", jobs: 4})
assert(defaults.mode == "debug")
assert(dict.get(chosen, "missing", "fallback") == "fallback")
assert(dict.get(chosen, "note", "fallback") == nil)

let public = dict.pick(chosen, ["mode", "jobs", "missing"])
assert(public == {jobs: 4, mode: "release"})
assert(dict.omit(chosen, ["note"]) == public)
assert(dict.from_items(dict.items(public)) == public)
print(dict.items(public))
```

The right map wins in a merge. `pick` ignores missing selected keys. A stored
`nil` is returned by `get`; only an absent key uses the fallback. `items` and
`values` follow sorted key order, making record-to-list transformations stable.

Use `dict.map_values` for a uniform unary transformation of values. Use an
ordinary map loop when the transformation also needs each key.

## 20.4 Compare groups with set algebra

```ratt
import "sets"

let requested = ["parser", "runtime", "parser"]
let available = set(["runtime", "lexer", "parser"])
let missing = sets.difference(requested, available)
assert(len(missing) == 0)
assert(sets.is_subset(requested, available))
assert(sets.is_disjoint(requested, ["exporter"]))
assert(sets.intersection(requested, ["runtime"]) == set(["runtime"]))
print(sets.union(requested, ["exporter"]))
```

Lists and sets can be mixed as operands. Duplicate list entries do not change
set membership. Structural equality also permits compound elements, such as
maps describing equivalent configurations.

Set iteration retains first-seen order; set display text sorts element
representations. Choose an explicit list order when output ordering is part of
a file format rather than relying on how a set is printed.

## 20.5 Build combinations and running totals

```ratt
import "iter"

let matrix = iter.product(["debug", "release"], ["c", "cxx"])
assert(matrix == [["debug", "c"], ["debug", "cxx"],
                  ["release", "c"], ["release", "cxx"]])
assert(iter.zip(["a", "b", "c"], [1, 2]) == [["a", 1], ["b", 2]])
assert(iter.enumerate(["a", "b"], start: 1) == [[1, "a"], [2, "b"]])
assert(iter.scan([3, 4, 5], 0, fn(total, n) { return total + n }) == [0, 3, 7, 12])
assert(iter.all([], fn(value) { return false }))
assert(not iter.any([], fn(value) { return true }))
```

`product` emits left-major Cartesian pairs. `zip` stops at the shorter input;
it does not require equal lengths. `scan` includes the initial accumulator.
`all`, `any`, and `find` stop as soon as their result is determined.

These APIs materialize their outputs. A Cartesian product has
`len(left) * len(right)` entries; chunking an already-created list does not turn
the earlier operation into a lazy iterator.

## 20.6 Compose normalization steps

```ratt
import "str" as text
import "collections"
import "functional" as functions
import "iter"

let normalize = functions.pipe([text.trim, text.lower])
let modes = collections.map([" Debug ", "RELEASE "], normalize)
assert(modes == ["debug", "release"])

let is_release = functions.compose(fn(mode) { return mode == "release" }, normalize)
assert(iter.find([" Debug ", " RELEASE "], is_release) == " RELEASE ")
let increment = functions.bind_first(fn(a, b) { return a + b }, 1)
assert(functions.repeat(increment, 3)(10) == 13)
```

`compose(outer, inner)` applies the inner function first; `pipe` applies its list
left-to-right. `find` returns the original matching element, not the normalized
callback result. `pipe` copies its callback list when created, so appending to
the original list later does not extend that pipeline.

Callbacks execute in the invoking evaluator's phase. A pipeline reaching
`proc.run`, `proc.env`, or `fs.write` during construction still raises
`E_PHASE_VIOLATION`. Pure composition itself is usable in a spec.

## 20.7 Generate a build matrix as a tracked output

Complete `Rattspec` in an otherwise empty project directory:

```ratt
project(name: "matrix-plan", version: "1.0.0", kind: "single")
import "iter"
import "collections"
import "json"
import "fs"

let pairs = iter.product(["debug", "release"], ["c", "cxx"])
let jobs = collections.map(pairs, fn(pair) {
  return {mode: pair[0], language: pair[1]}
})
let plan = rule(name: "plan", output: "build/plan.json")
action(plan) { fs.write("build/plan.json", json.stringify(jobs, pretty: true) + "\n") }
```

```sh
rattsc --lint Rattspec
rattbuild build plan
rattbuild build plan
```

Construction creates the four records deterministically. Execution writes the
JSON file; the second unchanged build skips it. The records and library helpers
are captured with the action. [Chapter 21](21-structured-data-and-text.md)
extends this pattern to transformations of declared input files.
