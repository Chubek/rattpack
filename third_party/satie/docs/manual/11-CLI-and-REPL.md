# CLI and REPL

Build these executables with `INSTALL_CLI=ON` (the default). The build-tree
paths are `build/cli/satie-cli` and `build/cli/satie-repl`; installation puts
them in the configured executable directory.

## Batch command line

```text
satie-cli [--engine native|dpll|cdcl] [--model]
          [--format auto|cnf|dimacs|bool|wcnf|opb|smt2|lisp] <file|->
```

| Argument | Behavior |
|---|---|
| `--engine` | Select a SAT engine; defaults to `cdcl`. |
| `--format` | Select a parser/solve route; defaults to `auto`. |
| `--model` | Print a satisfying assignment after SAT where supported. |
| `-` | Read input from standard input. |
| `-h`, `--help` | Print usage and exit successfully. |

`auto` recognizes DIMACS from a leading problem line after comments and
blank lines; otherwise it uses the restricted CNF DSL. Explicitly select
`dimacs` for headerless integer clauses and `bool` for full Boolean
expressions. [Language Frontends](9-Frontends.md) describes each syntax.

```sh
build/cli/satie-cli --engine cdcl --format dimacs --model problem.cnf
build/cli/satie-cli --format bool --model - <<'EOF'
(a | b) & (~a | c)
EOF
```

## Results and exit codes

Standard output begins with `SAT`, `UNSAT`, or, on supported routes,
`UNKNOWN`. Argument, I/O, and parse diagnostics go to standard error.

| Exit code | Meaning |
|---|---|
| `0` | SAT, an optimal feasible MaxSAT result, or a successful help request. |
| `1` | UNSAT. |
| `2` | Error or an UNKNOWN result printed by the ordinary result path. |

These are process exit codes; they differ from the
[C API and IPASIR status values](12-C-and-Foreign-Interfaces.md).
An UNSAT answer is a successful solver outcome even though its process
exit code is nonzero.

For ordinary SAT formats, model lines use numeric identifiers:
`x1 = TRUE`, `x2 = FALSE`. These can include Tseitin auxiliary variables
for `bool` inputs. The `lisp` route prints user-named Booleans. The `smt2`
CLI route prints the status only; access named SMT models through the C++
frontend API.

## Optimization routes

`--format wcnf` solves MaxSAT, prints `SAT` and `cost = <optimum>`, and
optionally prints a model. It reports `UNSAT` when the hard part is
infeasible. The current MaxSAT implementation drives CDCL internally, so
its engine argument does not choose a different optimization backend.

`--format opb` checks the parsed pseudo-Boolean constraints with CDCL. It
does not optimize a parsed `min:`/`max:` objective. Use
`optimize_pb_min`/`optimize_pb_max` in C++ for that operation.
SMT-LIB2 also selects its own Boolean/LIA route. Engine selection applies
directly to ordinary SAT and SatieLisp solving.

## Interactive session

```text
satie> (a | b) & (~a | c)
satie> :status
satie> :engine cdcl
satie> :solve
SAT
satie> :model
satie> :reset
satie> :load problem.cnf
satie> :solve
satie> :quit
```

| Command | Operation |
|---|---|
| `:load <file>` | Replace the active problem using automatic CNF/DIMACS parsing. |
| `:engine native\|dpll\|cdcl` | Select the engine used by the next `:solve`. |
| `:solve` | Solve the active problem and save its report. |
| `:model` | Print the assignment from the saved satisfying report. |
| `:count` | Count models with `NaiveSolver`, regardless of the selected solve engine. |
| `:status` | Show the selected engine and active clause/variable counts. |
| `:reset` | Clear the problem, accumulated input, and saved report. |
| `:help`, `:h`, `:?` | Show command help. |
| `:quit`, `:exit`, `:q` | Exit; end-of-input also exits. |

Bare input lines accumulate in an input buffer; after every line the REPL
tries to parse the complete buffer. Incomplete or malformed input prints
a diagnostic. Start a separate formula with `:reset`. `:load` replaces
the active problem but does not clear that accumulated buffer.

After replacing a problem or changing engines, run `:solve` before
reading `:model`: the saved report is from the last solve, and loading or
editing the problem does not automatically recompute it. `:count` uses
exhaustive enumeration and is intended for small instances.

The REPL accepts the CNF DSL and DIMACS rather than the CLI's entire
format portfolio. ANSI syntax coloring is a display feature; it does not
add comment forms or operators to the accepted grammar.

See [Solver Controls and Diagnostics](16-Solver-Controls-and-Diagnostics.md)
for the direct APIs for budgets, assumptions, and statistics.
