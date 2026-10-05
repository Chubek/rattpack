# Standard Library

## Including and linking helpers

The `stdlib/` directory provides header-defined helpers in
`satie::stdlib::<module>`, alongside Lua versions of many modules.
An in-tree consumer can link `satie::stdlib` and include `"Stdlib.hpp"`
or individual headers such as `"encoding/Encoding.hpp"`. This interface
target supplies the include path and links the solver.

Installed headers are under `include/satie/stdlib`. Include
`<satie/stdlib/Stdlib.hpp>` or
`<satie/stdlib/encoding/Encoding.hpp>` and link the installed
`satie::satie` target. For headers that include other module directories,
also add `<prefix>/include/satie/stdlib` to the include search path;
`satie::stdlib` currently exists only in the build tree.

## Module inventory

| Header | Main facilities |
|---|---|
| `arith/Arith.hpp` | Integer GCD/LCM, checked powers/factorials, primality, clamping. |
| `array/Array.hpp` | Membership, counts, indexing, duplicate removal, slices/reversal. |
| `constants/Constants.hpp` | Mathematical constants. |
| `list/List.hpp` | Transform, filter, fold, zip, ranges, predicates. |
| `map/Map.hpp` | Association-list lookup/update and map merging. |
| `variables/Variables.hpp` | `VarSupply`: fresh IDs, checkpoints, rollback. |
| `encoding/Encoding.hpp` | At-most/at-least/exactly-one CNF encodings. |
| `simplifier/Simplifier.hpp` | CNF preprocessing with a partial assignment and counters. |
| `datalog/Datalog.hpp` | Facts, Horn rules, bounded bottom-up derivation, queries. |
| `graphlib/Graphlib.hpp` | Directed graph storage, traversal, and topological ordering. |
| `graphviz/Graphviz.hpp` | DOT graph construction and label escaping. |
| `sched/Sched.hpp` | Dependency-ordered execution of named tasks. |
| `ffi/Ffi.hpp` | RAII handles for the C solver, theory-module, and plugin APIs. |
| `import/Import.hpp` | Load Lua files or snippets into an existing context. |
| `io/Io.hpp` | Read/write/append files and read line collections. |
| `path/Path.hpp` | Filesystem path decomposition, joining, and normalization. |
| `os/Os.hpp` | Environment values, directories, existence, CPU count. |
| `sys/Sys.hpp` | Library build info, Unix time, CPU count. |
| `fmt/Fmt.hpp` | Text conversion, joining, trimming, repetition, padding. |
| `regex/Regex.hpp` | Standard-library regex matching, replacement, and splitting. |
| `json/Json.hpp` | JSON value trees, parsing, serialization, escaping. |
| `yaml/Yaml.hpp` | Scalar/sequence/mapping value trees and a YAML subset parser. |
| `html/Html.hpp` | Escaping, tags, tables, and page rendering. |
| `latex/Latex.hpp` | Escaping, math/fragments/documents, CNF rendering. |
| `log/Log.hpp` | Log levels, records, and logger sinks. |
| `logsynth/Logsynth.hpp` | Structured event logs serialized as JSON. |
| `openai/Openai.hpp` | Chat-completion JSON payload construction and response-text extraction. |

`openai` operates on strings/value trees; callers provide their own HTTP
transport and authentication. The YAML parser implements its documented
subset rather than the entire YAML specification. Regex errors can be
handled through the `try_match_*` helpers, which return an optional result.

## Cardinality encoding and fresh variables

Auxiliary variable IDs must start after every variable already allocated
by the caller. The functions taking `first_fresh` return clauses rather
than updating a caller's supply; account for all generated auxiliary IDs
before generating another independent encoding.

```cpp
#include "Satie.hpp"
#include "encoding/Encoding.hpp"
#include "variables/Variables.hpp"
#include <cassert>

int main()
{
    satie::stdlib::variables::VarSupply ids;
    auto choices = ids.fresh_many(3);
    auto clauses = satie::stdlib::encoding::encode_exactly_one(
        choices, ids.checkpoint());
    satie::CNF problem(std::move(clauses));
    auto result = satie::solve(problem);
    assert(result.satisfiable());
    int selected = 0;
    for (auto variable : choices)
        selected += result.assignment.get_var(variable) == satie::Value::TRUE;
    assert(selected == 1);
}
```

`VarSupply::rollback` is for discarding speculative allocations. A
rollback does not rewrite clauses already using the discarded IDs.
For lower-level Boolean/arithmetic gates, use
`satie::theory::Encoder` from `SatieTheoryUtils.hpp`.

## Preprocessing and model reconstruction

`simplify_cnf` returns a `PreprocessResult` with `cnf`, `partial`, `stats`,
and `trivially_unsat`. The partial assignment records unit and pure-literal
choices. Reconstruct a model using those choices first, then residual
values for the remaining variables. Residual solvers can assign arbitrary
values to eliminated variables, so the saved partial assignment takes
precedence. Pure-literal elimination preserves satisfiability, but this
preprocessed residual is not a model-count-preserving replacement.

```cpp
#include "Satie.hpp"
#include "simplifier/Simplifier.hpp"
#include <cassert>

int main()
{
    satie::CNF original({{-1}, {1, 2}, {3, 4}, {-3, -4}});
    auto reduced = satie::stdlib::simplifier::simplify_cnf(original);
    assert(!reduced.trivially_unsat);
    auto result = satie::solve(reduced.cnf);
    assert(result.satisfiable());
    satie::Assignment model(original.variable_count());
    reduced.partial.for_each_assigned([&](satie::Var var, satie::Value value) {
        model.assign(var, value == satie::Value::TRUE);
    });
    result.assignment.for_each_assigned([&](satie::Var var, satie::Value value) {
        if (!model.is_assigned(var))
            model.assign(var, value == satie::Value::TRUE);
    });
    model = model.completed();
    assert(satie::is_formula_satisfied(original, model));
}
```

`CNF::simplified()` is a smaller transformation: it removes tautologies,
duplicate/subsumed clauses, and preserves the original variable universe.
It does not perform unit/pure-literal assignment extraction.

## Datalog and scheduling

`datalog::Database` stores string tuples. Rule variables are marked in
`Atom::is_var`; ground atoms can be constructed with `ground_atom`.
`evaluate()` derives facts until a fixpoint or the iteration cap. Because
reaching the cap returns without a completion status, a missing fact
after capped evaluation is not proof that the rule system cannot derive it.

`sched::TaskGraph` runs dependency-ready tasks in lexicographic order,
returning named string results. Unknown dependencies and cycles throw.
This scheduler executes sequentially; it is not a parallel solver engine.

## Lua counterparts

Lua modules are installed under `share/satie/stdlib/<module>/<module>.lua`.
Load them with the import helper described in
[Plugins and Lua](13-Plugins-and-Lua.md). C++ and Lua interfaces have
language-specific naming and value representations; consult the actual
module file for its returned table and functions.

See [Build and Installation](10-Build-and-Installation.md) for include
paths, and [Solver Controls and Diagnostics](16-Solver-Controls-and-Diagnostics.md)
for checking assignments and interpreting counters.
