# Plugins and Lua

## Command host

`SatiePlugin.hpp` provides an in-process command API:

- `PluginArguments` is `std::vector<std::string>`.
- `PluginCommand` accepts those arguments and returns `std::string`.
- `PluginHost::register_command`, `invoke`, `has_command`, and `commands`
  manage the command table.
- `Plugin` supplies `info()` and `install(PluginHost&)`.
- `PluginManager` owns plugin instances and installs them into a host.

```cpp
#include "SatiePlugin.hpp"
#include <cassert>

int main()
{
    satie::PluginHost host;
    host.register_command("echo", [](const satie::PluginArguments &args) {
        return args.empty() ? std::string{} : args.front();
    });
    assert(host.has_command("echo"));
    assert(host.invoke("echo", {"hello"}) == "hello");
}
```

Empty names, null callbacks, and duplicate registration throw
`std::invalid_argument`; unknown invocation throws `std::out_of_range`.
Callback exceptions propagate to C++ callers. Host table operations are
mutex-protected and callbacks run after the lookup lock is released.
Provide any synchronization required by callback-owned state.

The host must outlive a manager using it and any script callbacks that
refer to it. A callback capturing a plugin instance also needs that
instance alive during invocation. The API has no command-unregister or
dynamic shared-object loader operation; installation is through C++
objects, C callbacks, or the Lua bridge.

## Standard plugins

The three header-defined plugins live in `stdplugin/`:

| Plugin | Command | Input/result |
|---|---|---|
| `SemVerValidator` | `semver.valid` | One SemVer string; returns `"true"` or `"false"`. |
| `DependencySAT` | `dependency.sat` | Each argument is a space-separated integer clause without `0`; returns `"SAT"` or `"UNSAT"`. |
| `PackageResolver` | `package.resolve` | `package=version` entries; selects the greatest requested SemVer for each package and returns comma-separated entries. |

For an in-tree consumer, the `satie_stdplugin` interface target adds the
repository root to the include path:

```cpp
#include "SatiePlugin.hpp"
#include "stdplugin/SemVerValidator/SemVerValidator.hpp"
#include "stdplugin/DependencySAT/DependencySAT.hpp"
#include "stdplugin/PackageResolver/PackageResolver.hpp"
#include <cassert>

int main()
{
    satie::PluginHost host;
    satie::PluginManager plugins(host);
    plugins.emplace<satie::stdplugin::SemVerValidator>();
    plugins.emplace<satie::stdplugin::DependencySAT>();
    plugins.emplace<satie::stdplugin::PackageResolver>();
    assert(host.invoke("semver.valid", {"1.2.3-alpha.1"}) == "true");
    assert(host.invoke("dependency.sat", {"1", "-1"}) == "UNSAT");
    assert(host.invoke("package.resolve", {"core=1.9.0", "core=1.10.0"})
           == "core=1.10.0");
}
```

Installed plugin headers are under `include/satie/stdplugin/`, so an
installed include is
`<satie/stdplugin/SemVerValidator/SemVerValidator.hpp>`. `PackageResolver`
selects among requested versions; it does not itself load repository
metadata or encode a transitive package-dependency graph.

## Embedded Lua bridge

Satie uses the bundled QaMRpp interpreter. `LuaPlugin::install_library`
puts an `lsatie` table into a `qamrpp::Context`. `LuaPlugin::run` can
execute a source string with a supplied context or create an owned one.

| Lua function | Result |
|---|---|
| `lsatie.solve(formula, engine?)` | Table with `status`, `satisfiable`, `engine`, and `model`. |
| `lsatie.satisfiable(formula, engine?)` | Boolean SAT predicate. |
| `lsatie.parse(formula)` | Table with `clauses`, `variables`, and DIMACS text. |
| `lsatie.invoke(name, args?)` | String returned by a host command. |
| `lsatie.commands()` | One-based array of registered command names. |
| `lsatie.register(name, function)` | Register a script callback taking a one-based argument table. |

Formula strings use automatic CNF/DIMACS parsing, and engine strings are
`native`, `dpll`, or `cdcl` (default). The model table uses stringified
variable IDs such as `"1"` as keys. This bridge drives the ordinary SAT
facade; use typed C++ APIs for theory constraints and advanced controls.

```cpp
#include "SatiePlugin.hpp"
#include <cassert>

int main()
{
    satie::PluginHost host;
    qamrpp::Context context;
    satie::LuaPlugin::install_library(context, host);
    auto result = context.run(
        "lsatie.register('lua.echo', function(args) return args[1] end); "
        "local solved = lsatie.solve('(x) & (~y)', 'cdcl'); "
        "return solved.status");
    assert(result->string_value == "SAT");
    assert(host.invoke("lua.echo", {"hello"}) == "hello");
}
```

With an externally supplied context, keep it alive while its callbacks
remain registered. The context-free `LuaPlugin::run` path retains its
owned context through registered callbacks. QaMRpp is an embedded dialect;
its available library operations determine what a script can execute.

## Loading Lua modules

The modules under `stdlib/<name>/<name>.lua` return tables. In this
embedding, `require`/`dofile` are stubs; load files through
`satie::stdlib::import::load_lua_file(context, path)` and place the
returned value into `context.globals` under the desired module name.
`run_lua_snippet` executes a string in the same context.

The installed Lua path is `share/satie/stdlib`. Lua examples in
`examples/Lua/` illustrate direct `lsatie` calls. The C callback API is
covered in [C and Foreign Interfaces](12-C-and-Foreign-Interfaces.md), and
the helper/module inventory in [Standard Library](14-Standard-Library.md).
