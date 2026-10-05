# Solver Controls and Diagnostics

## Facade versus concrete engines

`SolveOptions` currently selects only an engine. `Solver::solve` and
`solve_with_report` construct a fresh concrete engine for each call.
Use `CDCLSolver` directly for assumptions, budgets, restart settings,
minimization, and learned-clause inspection. Reusing a concrete solver
also starts a fresh search on each solve; its learned clauses and search
counters are not retained as an incremental learning cache.

## CDCL settings

| Method | Default/meaning |
|---|---|
| `set_conflict_budget(n)` | `0` means unlimited; a reached search conflict budget yields UNKNOWN. |
| `set_restarts_enabled(bool)` | Enabled by default. |
| `set_luby_scale(n)` | Default 128 conflicts times the Luby sequence; zero is normalized to one. |
| `set_max_learned_clauses(n)` | Default 4000; database reduction runs at restart points when exceeded. |
| `set_enable_minimization(bool)` | Enabled by default; recursively removes redundant learned literals. |

Budgets count conflicts rather than elapsed time. A root contradiction
or completed search can decide the formula before a budget returns
UNKNOWN. Assumption-core minimization uses separate unlimited probe
solves, so a budget is not a wall-clock bound on the complete operation.

## Assumptions and cores

```cpp
#include "Satie.hpp"
#include <cassert>

int main()
{
    satie::CDCLSolver solver(satie::CNF({{1, 2}}));
    auto under = solver.solve_under({-1, -2});
    assert(under.unsatisfiable());
    assert(solver.last_unsat_core().size() == 2);
    auto ordinary = solver.solve();
    assert(ordinary.satisfiable());
    assert(satie::is_formula_satisfied(solver.problem(), ordinary.assignment));
}
```

Assumptions are signed, nonzero literals within the loaded variable
range. Explicitly declare unused variables in the CNF before assuming
them. Invalid assumptions throw `std::invalid_argument`.
`last_unsat_core()` contains a deletion-minimized subset of the actual
assumption literals. It is empty when the base formula itself is UNSAT.
Deletion-minimal does not mean minimum cardinality. Obtain the core
after the UNSAT call and before starting another solve.

`last_learned_clause()` exposes the most recently analyzed learned
clause; `learned_clause_count()` counts indices currently retained in
the database. These are search diagnostics rather than a serialized
proof or a persistent clause-learning API. For persistent clause input
and next-solve assumptions, use the
[IPASIR-style frontend](9-Frontends.md).

## Statistics

`SolverReport::statistics` holds exactly the optional statistics for the
selected engine. Concrete engines expose `statistics()`; CDCL also has
the `stats()` synonym. Counters reset per solve (and the native counter
resets for `count_models`). Copy a concrete engine's statistics before
the next operation if you need a saved snapshot.

| Engine | Counters |
|---|---|
| Native | `assignments_tested`, `recursive_calls`, `conflicts`, `satisfiable_leafs`, `unsatisfiable_leafs`. |
| DPLL | `recursive_calls`, `decisions`, `propagations`, `pure_literal_eliminations`, `backtracks`, `conflicts`. |
| CDCL search | `decisions`, `propagations`, `conflicts`, `learned_clauses`, `restarts`, `backjumps`. |
| CDCL detail | `root_propagations`, `analysed_literals`, `deleted_clauses`, `reduced_databases`, `assumptions`, `tautologies_removed`, `max_learned_clause_length`, `activity_rescales`, `minimized_literals`, `conflicts_since_restart`. |

The native engine prunes conflicting partial assignments, so
`assignments_tested` counts reached complete assignments, not every
possible valuation. CDCL's cumulative `learned_clauses` includes learned
units and differs from the size of the retained non-unit database.
Record the engine, input, configuration, compiler, and elapsed time
alongside counters when comparing runs. SAT models need not be unique.

## Memory resource

`SatieMemory.hpp` exposes the non-copyable `MemoryResource`, a
`std::pmr::memory_resource` implemented with bundled memtkx allocators:

- `MemoryLifetime::Persistent` (default) reuses freed small allocations.
- `MemoryLifetime::Transient` uses bump allocation for small objects.
- Default pool block size is 64 KiB; the large-object threshold is 4096
  bytes. Requests at/above the threshold or with over-alignment use
  separate regions.

```cpp
#include "SatieMemory.hpp"
#include <cassert>
#include <vector>

int main()
{
    satie::MemoryResource memory(satie::MemoryLifetime::Transient);
    {
        std::pmr::vector<int> scratch(&memory);
        scratch.push_back(42);
        assert(memory.statistics().live_bytes > 0);
    }
    assert(memory.statistics().live_bytes == 0);
    memory.release();
    assert(memory.statistics().reserved_bytes == 0);
}
```

The resource must outlive its PMR clients. Destroy clients before
`release()`, which invalidates allocations, frees regions, and resets
statistics. Individual transient small-object deallocation updates live
accounting but does not rewind the bump pool. Large regions are reclaimed
when their allocations are deallocated.

Memory counters are `allocations`, `live_bytes`, `peak_bytes`,
`reserved_bytes`, `pooled_allocations`, and `large_allocations`. Live
bytes describe outstanding requested storage, while reserved bytes
describe backing regions. The allocator/statistics methods are locked;
that does not make a client container safe for concurrent mutation.

## Validation and tests

After SAT, validate a Boolean model with
`is_formula_satisfied(problem, result.assignment)`. UNKNOWN is a third
outcome, not an alias for UNSAT. A satisfying DPLL assignment may leave
don't-care variables unknown; `Assignment::completed` creates a total
extension when needed.

With testing enabled, CTest registers `satie_tests`, `satie_sat_tests`,
and `satie_memory_tests`; examples and D frontend tests are added when
their build options are enabled. The memory tests cover PMR growth,
range construction, alignment, and accounting, and turn GCC array-bounds
warnings into errors for that target.

```sh
ctest --test-dir build --output-on-failure
ctest --test-dir build -R 'satie_sat_tests|satie_memory_tests' --output-on-failure
```

Use the reported test failures and generated documentation warnings when
checking a specific revision. The source tree's test definitions do not
by themselves establish that every test passes on every toolchain.

See [Possible Errors](7-Possible-Errors.md) for exception/result handling,
and [Build and Installation](10-Build-and-Installation.md) for the build
and documentation targets.
