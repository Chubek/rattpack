# Parsing, ASTs, and DSLtk

## Choosing the parser

| Input | Entry point | Representation |
|---|---|---|
| Already-clausal symbolic CNF | `parse_cnf` or `parse(..., ParseFormat::CNF)` | `CNF`; symbols interned in first-occurrence order. |
| Integer DIMACS clauses | `parse_dimacs` or `parse(..., ParseFormat::DIMACS)` | `CNF` with declared variable universe preserved. |
| Full Boolean expression | `frontend::parse_bool_formula` | `BoolFormula` with Tseitin CNF and an explicit symbol table. |
| SMT-LIB2 or SatieLisp forms | Corresponding frontend API | Parsed script/formula and named model where supported. |

The restricted CNF DSL has this shape:

```text
formula    := clause ('&' clause)*
clause     := '(' literal ('|' literal)* ')'
literal    := ('~' | '!')? identifier
identifier := [A-Za-z_][A-Za-z0-9_]*
```

Whitespace is permitted between clauses/operators, and an empty input
represents the empty, satisfiable formula. Empty `()` is rejected; use
an empty in-memory clause or a DIMACS `0` clause to express false.
The restricted grammar does not add full-expression nesting, `->`,
Boolean constants, or source comments. An identifier such as `x42` is a
symbolic name, not a request for DIMACS variable 42.

DIMACS permits comment lines starting with `c`, an optional `p cnf`
header, and a `%` end marker. Clauses end with `0`; they may span lines.
The auto detector only selects DIMACS when a problem line leads the
meaningful input, so explicitly select DIMACS for headerless clauses.

The full Boolean parser supports additional operators/constants and
returns a symbol table; see [Language Frontends](9-Frontends.md).
In C++, its named variables are assigned in sorted-name order before
the auxiliary variables. Use `symbols.lookup(name)`/`symbols.name(id)`
rather than depending on parser-specific numbering.

## Parsing backend and diagnostics

`src/SatieParsing.cpp` integrates the bundled libglr grammar/parser for
DIMACS and frontend syntax. The restricted `CNFParser` and the public
DSLtk combinators have their own interfaces. Parsed CNF containers are
normalized through the shared literal/variable conventions.

Satie parsers report `satie::ParseError` with a `diagnostic` containing
line, column, and message. DSLtk's parser result error is a separate
`dsl::ParseError` value with an offset, failure kind, and expected labels.
[Possible Errors](7-Possible-Errors.md) covers these contracts.

## Problem DAG and DOT

`cnf_to_dag` makes a value-type AST with `cnf`, `clause`, and `literal`
nodes; each literal contains `var` and `sign` leaves. `dag_to_dot`
interns repeated literal nodes in the emitted graph. This is a view of
the CNF, not the CDCL implication trail or a proof certificate.

```cpp
#include "Satie.hpp"
#include <cassert>
#include <iostream>

int main()
{
    satie::CNF problem({{1, 2}, {-1, 3}});
    auto dag = satie::cnf_to_dag(problem);
    assert(dag.root.tag() == "cnf");
    std::cout << satie::dag_to_dot(dag);
}
```

Capture the output and render it with Graphviz:

```sh
build/examples/example_build_ast
dot -Tsvg problem.dot -o problem.svg
```

`example_build_ast` prints both an AST dump and DOT plus explanatory
text; extract its DOT portion or write `cnf_to_dot(problem)` directly
to `problem.dot` before rendering.

## DSLtk building blocks

`DSLtk.hpp` is a standalone header-only C++20 toolkit in namespace `dsl`.
It supplies reusable value/predicate/parser utilities and optional CRTP
mixins through `dsl::DSL<Derived, Features...>`.

| Facility | API |
|---|---|
| Pipelines | `pipe`, wrapped values, `operator\|`. |
| Predicates | `predicate`, `&`, `\|`, `!`. |
| Pattern matching | `match`, `when`, `otherwise`, limited compile-time pattern helpers. |
| AST construction | `ASTNode`, `leaf<"tag">`, `node<"tag">`, `dump`. |
| Rewriting | `rule`, `rewrite_set`, bottom-up `apply`. |
| Expression templates | Lazy arithmetic trees evaluated with `eval`. |
| Custom literals | `lit`, `literal_set`, `parse_literal`; native C++ UDLs are defined by the caller. |
| Memoization/laziness | `memoize`, `clear_cache`, `Lazy::get`/`force`. |
| Optional/result flows | `Maybe`, `Result`, mapping/filtering/error access. |
| Parsers | `Parser`, `ch`, `satisfy`, sequencing, alternatives, repetition. |
| Task pipelines | `Task`, `TaskChain`, `TaskState`, `run`, stop/continue policies. |

Memoized and lazy values are not inherently synchronized. Rewrite sets
stop at a fixpoint or `max_iterations` (default 100). Constructing or
rewriting a generic `dsl::ASTNode` does not automatically turn it into
a solver CNF; the caller supplies that translation.

## Parser combinator example

```cpp
#include "DSLtk.hpp"
#include <cassert>

int main()
{
    auto pair = dsl::ch('a') & dsl::ch('b');
    auto parsed = dsl::run_parser(pair, "ab");
    assert(parsed.value.has_value());
    assert(parsed.value->first == 'a' && parsed.value->second == 'b');
    auto trailing = dsl::run_parser(pair, "abc");
    assert(!trailing.value.has_value());
    assert(trailing.error.pos == 2);
}
```

`run_parser` requires consumption of the entire input. `p & q` returns
a pair; `p | q` selects between parsers of the same result type;
`*p` returns zero or more results; `optional(p)` makes a result optional.
A repeated parser must consume input on success, or repetition cannot
progress.

Errors distinguish `Soft` failure from `Committed` failure. Alternatives
retry after a soft failure; `try_parse(p)` explicitly restores the cursor
and makes a failure soft. `labeled(p, text)` replaces expected labels;
merged errors retain the farthest failure position.

Related: [Encoding for SAT](2-Encoding-for-SAT.md),
[Using Satie](6-Using-Satie.md), and
[Standard Library](14-Standard-Library.md).
