# C and Foreign Interfaces

## Headers and linking

`Satie.h`, `SatieModule.h`, and `SatiePlugin.h` are C-compatible headers
with opaque handles. Their implementations are in the compiled C++
library. A CMake project using C sources can enable `LANGUAGES C CXX`,
link `satie::satie`, and use the C++ linker for the executable:

```cmake
add_executable(c_client main.c)
target_link_libraries(c_client PRIVATE satie::satie)
set_target_properties(c_client PROPERTIES LINKER_LANGUAGE CXX)
```

## Solver handle lifecycle

1. Create a handle with `satie_solver_create`.
2. Load text with `satie_solver_load_dimacs`/`satie_solver_load_cnf`, or
   append clauses with `satie_solver_add_clause`.
3. Solve with `SATIE_C_NATIVE`, `SATIE_C_DPLL`, or `SATIE_C_CDCL`.
4. Read the status, variable count, and satisfying values.
5. Reset for a new problem, or destroy the handle when finished.

Loading or appending successfully invalidates the cached result.
`satie_solver_reset` also discards all clauses. Pass a count-delimited
literal array without a DIMACS terminator to `add_clause`; a zero-length
clause is valid and makes the formula UNSAT.

```c
#include "Satie.h"
#include <stdio.h>

int main(void)
{
    SatieSolver *solver = satie_solver_create();
    if (!solver) {
        fprintf(stderr, "%s\n", satie_last_error());
        return 2;
    }
    const int clause[] = {1};
    if (satie_solver_add_clause(solver, clause, 1) != 0) {
        fprintf(stderr, "%s\n", satie_last_error());
        satie_solver_destroy(solver);
        return 2;
    }
    int status = satie_solver_solve(solver, SATIE_C_CDCL);
    int success = status == SATIE_C_SAT &&
                  satie_solver_variable_value(solver, 1) == 1;
    satie_solver_destroy(solver);
    return success ? 0 : 1;
}
```

## Status conventions

| Interface | SAT | UNSAT | UNKNOWN | Error reporting |
|---|---|---|---|---|
| `Satie.h` | `1` | `0` | `-1` | Failure returns plus `satie_last_error()`. |
| `SatieModule.h` | `1` | `0` | `-1` | Module check errors return `-2`. |
| IPASIR-style API | `10` | `20` | `0` | See the frontend wrapper contract. |
| CLI process | `0` | `1` | `2` on the ordinary result path | Diagnostics on stderr. |

`satie_solver_variable_value(handle, var)` has its own convention:
`1` is true, `0` is false, and `-1` is unavailable/unknown. Read it only
after a SAT solve. `satie_solver_status` returns UNKNOWN before solving
or after the cached result is invalidated.

Creation returns NULL on failure; text-loading/clause-adding functions
return zero on success and nonzero on failure. `satie_last_error()` is a
thread-local diagnostic of a failing call, not an error flag cleared by
every successful call. Copy a diagnostic when retaining it across calls.
`satie_version()` and `satie_build_info()` provide linked-library metadata
whose strings remain valid for the process lifetime. Use the declared
engine constants; unrecognized engine integers currently fall back to CDCL.

## Theory module handles

`satie_module_count` and `satie_module_name_at` enumerate registered theory
names. Create with `satie_module_create("BV")`, append Boolean clauses,
check, and destroy with `satie_module_destroy`. Unknown names return
NULL. The module error channel is `satie_module_last_error()`.

The registry/module interface carries a CNF problem. It does not expose
the typed theory declarations and constraints such as BV widths or IDL
inequalities. Use the concrete C++ solvers described in
[Theory Solvers](8-Theories.md) to construct those problems.
Names returned while enumerating modules are thread-local snapshots;
copy each name before the next enumeration call.

## C plugin callbacks

`SatiePlugin.h` provides a separate `SatieCPluginContext` with
create/destroy/register/invoke operations. A `SatieCCommandFn` receives
NUL-terminated argument strings, their count, and caller-owned `userdata`.
It returns a NUL-terminated result string that the context copies, or
NULL for failure. Keep callback data alive while the command can run.

`satie_plugin_invoke` writes into a caller-supplied output buffer. Its
return is nonzero on unknown command, callback failure, or truncation;
include room for the NUL terminator. Report failures using
`satie_plugin_last_error()`. The C++/Lua equivalents are described in
[Plugins and Lua](13-Plugins-and-Lua.md).

## IPASIR and language bindings

The `satie_ipasir_*` functions are declared with C linkage in
`SatieFrontendIPASIR.hpp`; that header otherwise requires C++. The
provided D declarations live in `frontends/IPASIR.d`. This is Satie's
prefixed IPASIR-style interface, with the listed add/assume/solve/value/core
functions; it is not a complete drop-in implementation of every IPASIR
extension. See the [frontend chapter](9-Frontends.md) for a working example.

`bindings/Satie.i` is a SWIG interface sketch. The
`generate-bindings.sh` script currently prints a message; CMake does not
build or install a Python or other SWIG module. Foreign-language clients
can bind the implemented opaque C APIs, or use the compiled D ports.
Satie currently installs static archives, so a `ctypes`-style client also
needs a separately built shared-library wrapper.
