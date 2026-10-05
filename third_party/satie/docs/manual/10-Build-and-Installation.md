# Build and Installation

## Requirements and dependencies

Satie builds a compiled static library, `satie`, with a C++20 public API.
Many solver routines are inline, but the facade, parser backend, memory
resource, C entry points, and component registration require the library.
Link `satie::satie` rather than relying on includes alone.

The CMake build requires:

- CMake 3.16 or newer, a C compiler, and a C++20 compiler;
- a platform thread implementation, discovered by `find_package(Threads)`;
- the bundled `third_party/libglr`, `third_party/memtkx`, and
  `third_party/QaMRpp` sources/headers;
- libglr's klib and CTL sources, either supplied locally or fetched at
  pinned revisions by CMake.

LDC (`ldc2`), DMD (`dmd`), or GDC (`gdc`) enables the optional D frontend
archive. Doxygen and Graphviz `dot` are used for generated documentation.
Node.js 18 or newer is needed only to run the distributed language server.

## Configure, build, and test

Run from the repository root:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 4
ctest --test-dir build --output-on-failure
```

The default build includes the library, CLI/REPL, C++ examples, and test
executables. When a D compiler is found, it also builds
`frontends/libsatie_frontends.a` and, with testing enabled, the D test
executables. CTest runs the executables built by these rules.

With CMake 3.21 or newer, the `default` configure preset uses Ninja and
the same `build/` directory: `cmake --preset default`. Choose a fresh
build directory when changing compiler or generator.

## Configuration options

| Option | Default | Purpose |
|---|---|---|
| `INSTALL_CLI` | `ON` | Build and install `satie-cli`, `satie-repl`, and the TermScript library target. |
| `BUILD_TESTING` | `ON` | Build and register the C++ and enabled D tests. |
| `BUILD_EXAMPLES` | `ON` | Build C++ examples and copy frontend sample data. |
| `BUILD_STDPLUGIN` | `ON` | Make the standard-plugin interface target available and install its headers. |
| `BUILD_D_FRONTENDS` | `ON` if a D compiler is found | Build and install the D frontend archive independently of testing. |
| `D_COMPILER` | First available `ldc2`, `dmd`, or `gdc` | Explicit path to the selected D compiler. |
| `GENERATE_DOCS` | `OFF` | Generate Doxygen HTML during the build. |
| `SATIE_FETCH_PARSER_DEPS` | `ON` | Fetch missing klib/CTL sources into the build tree. |
| `SATIE_KLIB_SOURCE_DIR` | Bundled klib directory | Override with a directory containing `kalloc.c` and the klib headers. |
| `SATIE_CTL_SOURCE_DIR` | Bundled CTL directory | Override with a directory containing `ctl/vec.h`. |
| `INSTALL_FISH`, `INSTALL_ZSH`, `INSTALL_BASH` | `OFF` | Install shell-completion assets. |
| `INSTALL_VIM`, `INSTALL_LSP`, `INSTALL_SUBLIME` | `OFF` | Install editor/language-server assets. |

To request D compilation explicitly, use
`-DBUILD_D_FRONTENDS=ON -DD_COMPILER=/path/to/ldc2`. An explicitly enabled
D build requires a usable supported compiler.

## Offline parser dependencies

An offline build can use existing complete dependency checkouts:

```sh
cmake -S . -B build-offline \
  -DSATIE_FETCH_PARSER_DEPS=OFF \
  -DSATIE_KLIB_SOURCE_DIR=/path/to/klib \
  -DSATIE_CTL_SOURCE_DIR=/path/to/ctl
cmake --build build-offline --parallel 4
```

The pinned revisions are specified in `cmake/SatieBackends.cmake`.
Fetches, copied dependency headers, and compiled output belong to the
build tree; no installation of libglr as a system package is required.

## CMake consumers

For an in-tree consumer, add Satie with `add_subdirectory` and link
`satie::satie`. For an installed consumer:

```cmake
cmake_minimum_required(VERSION 3.16)
project(MySolverApplication LANGUAGES CXX)
find_package(Satie CONFIG REQUIRED)
add_executable(my_solver main.cpp)
target_link_libraries(my_solver PRIVATE satie::satie)
```

The target carries the C++20 requirement, public include directory, and
static parser/thread link dependencies. `satie::frontends` additionally
represents the D archive when enabled; it retains the C++ solver dependency.
The build-tree-only `satie::stdlib` target supplies the standard-library
include path; see [Standard Library](14-Standard-Library.md) for installed
header usage.

## Installation

```sh
cmake --install build --prefix /path/to/satie-install
```

GNUInstallDirs controls the precise `lib`, `include`, `share`, and
documentation locations. Installation includes the static libraries,
public headers, CMake package files, standard-library headers/Lua modules,
and enabled CLI, D frontend, example, and distribution assets. Point
`CMAKE_PREFIX_PATH` at the installation prefix when configuring a consumer.

## Documentation and examples

```sh
cmake -S . -B build-docs -DGENERATE_DOCS=ON
cmake --build build-docs --target docs
```

HTML is written to `build-docs/docs/doxygen/html/index.html`; documentation
warnings are recorded in `build-docs/docs/doxygen-warn.log`. The front page
links the complete manual. With documentation disabled, the `docs` target
prints instructions for enabling it.

`example_basic_solve`, `example_build_ast`, and `example_frontends` are
compiled targets. `examples/DSL/*.satie`, `examples/Lua/`, and
`examples/Frontends/` provide input/script data. The TermScript C library
currently contains a stub entry point; `satie-cli` and `satie-repl` are the
working command-line interfaces.

## Editor and shell integration

The `INSTALL_*` distribution switches install data under
`share/satie/{fish,zsh,bash,vim,lsp,sublime-syntax}`. Connect those locations
to your shell/editor's runtime paths. The `satie-distrib` target prints
installation guidance.

The dependency-free language server starts with
`node distrib/lsp/server/index.js` over standard input/output. It provides
document synchronization, selected DIMACS/parenthesis diagnostics,
completion, and hover. Its syntax checks cover a smaller subset than the
library parsers; use the CLI to parse and solve an input authoritatively.

Next: [CLI and REPL](11-CLI-and-REPL.md), or
[C and Foreign Interfaces](12-C-and-Foreign-Interfaces.md).
