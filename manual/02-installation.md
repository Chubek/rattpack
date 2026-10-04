# 2. Installation and building from source

[Previous: Overview](01-overview.md) · [Contents](README.md) · [Next: First project](03-first-project.md)

## 2.1 Prerequisites

Rattpack is implemented in D and bootstrapped with DUB. Building the repository
also compiles its pinned native C libraries.

| Requirement | Purpose |
| --- | --- |
| DUB | Resolve pinned D dependencies and bootstrap the applications |
| LDC (`ldc2`) or DMD (`dmd`) | Compile the D applications and shared runtime |
| A C compiler and linker | Compile the native bridge, BLAKE3, libgit2, zlib, xz |
| CMake 3.20 or newer | Configure the repository's native-library build |
| Git | Obtain the checkout and its pinned submodules |
| Python 3 | Run repository build helpers |
| OpenSSL development headers and libraries on POSIX | Link the native/runtime dependencies |

The repository's integration tests require Python **3.11 or newer**, because the
test harness reads TOML with `tomllib`. They additionally use C and C++ compilers,
a D compiler, CMake, GNU Make, Ninja, and Meson.

Source acquisition and the first DUB dependency download require access to the
relevant remotes or a previously populated dependency cache. Normal project
builds use dependencies already fetched by `rattpkg`.

## 2.2 Prepare the checkout

From the repository root:

```sh
git submodule update --init --recursive
```

The four native-library directories under `third_party/` are Git submodules.
Their recorded commits are part of the dependency pinning policy. The D package
versions are pinned in `dub.selections.json`; Git mirrors of those dependencies
are declared in the repository's `Rattpkg`.

Do not replace the pinned native directories with arbitrary system versions when
reproducing the repository build. The source-tree bootstrap compiles them into
archives in `build/`.

## 2.3 Bootstrap with LDC

LDC is the default compiler in the shipped configuration:

```sh
dub build -c rattbuild --compiler=ldc2
./build/rattbuild build --warnings-as-errors
```

The first command builds the shared runtime and `rattbuild`. The second command
evaluates Rattpack's own `Rattspec` and builds the runtime and all three command-
line applications. This is the repository's **self-hosted**, or dogfood, build.

Each application can also be bootstrapped directly:

```sh
dub build -c rattpkg --compiler=ldc2
dub build -c rattsc --compiler=ldc2
```

The self-hosted build selects its compiler from `toolchain.d` in the Rattpack
configuration. DUB's `--compiler` option chooses the bootstrap compiler; it does
not rewrite that configuration.

## 2.4 Bootstrap with DMD

Use DMD consistently for the shared runtime, applications, and plugins:

```sh
dub build -c rattbuild --compiler=dmd
dub build -c rattpkg --compiler=dmd
dub build -c rattsc --compiler=dmd
```

For self-hosting, set the following in your configuration before invoking the
DMD-built `rattbuild`:

```toml
[toolchain]
d = "dmd"
```

Then run:

```sh
./build/rattbuild build --warnings-as-errors
```

See [chapter 9](09-configuration.md) for the configuration location. Repository
helpers accept `DC`, for example:

```sh
DC=dmd python3 tools/dogfood.py plugins
```

`DC` controls those helpers. It is separate from the configuration used to
construct ordinary build graphs.

## 2.5 Build products and library lookup

The output directory contains:

| Product | POSIX | macOS | Windows |
| --- | --- | --- | --- |
| Build application | `rattbuild` | `rattbuild` | `rattbuild.exe` |
| Package application | `rattpkg` | `rattpkg` | `rattpkg.exe` |
| Interpreter | `rattsc` | `rattsc` | `rattsc.exe` |
| Shared implementation | `librattpack.so` | `librattpack.dylib` | `rattpack.dll` |

The executables depend on the shared implementation and the compiler's shared D
runtime. The Linux bootstrap uses an executable-relative `$ORIGIN` runtime
search path; macOS uses `@loader_path`. Keeping the applications and Rattpack
shared library in one directory preserves that layout. The required D runtime
and system libraries must also be available to the operating-system loader.

To use the checkout's applications from other directories in a POSIX shell:

```sh
export PATH="/absolute/path/to/rattpack/build:$PATH"
rattbuild --version
rattpkg --version
rattsc --version
```

For PowerShell:

```powershell
$env:Path = "C:\path\to\rattpack\build;" + $env:Path
rattbuild --version
```

Install the built applications, shared library, profiles, templates, and manuals
with the repository installer (defaults to `~/.local`):

```sh
./install.sh
./install.sh --prefix /path/to/prefix
```

Pass `--build` to bootstrap all three applications with DUB before installing,
and `--compiler=dmd` to select DMD. Prepare the submodules first as described in
section 2.2. Use `--dry-run` to preview an existing build without copying files;
`--destdir` stages the prefix for packaging. `--with-plugins` includes the native
exporters. On Windows, invoke `python tools/install.py` with the same options.

## 2.6 Platform setup

### POSIX systems

Ensure `cc`, `c++`, CMake, and the selected D compiler are on `PATH`. A typical
Debian/Ubuntu development setup also installs the OpenSSL development package
(`libssl-dev`). Bubblewrap is optional; when usable, the POSIX backend uses it
to restrict subprocess writes during actions.

### macOS

Install a C toolchain, CMake, Python, and the selected D compiler. The runtime
configuration links the macOS Security and CoreFoundation frameworks and
`iconv`, in addition to its configured native dependencies. The backend uses
XDG-style configuration and cache locations, just as POSIX does.

### Windows

Use a compiler/linker environment compatible with your D compiler and CMake
generator. The native build links the relevant Windows system libraries. The
repository's Windows DUB pre-build command invokes `python`, so that name must
resolve to a Python 3 installation. Build executables end in `.exe` and native
plugins in `.dll`.

Ordinary C/C++ target lowering currently uses GCC/Clang-style options. A Windows
toolchain used for those declarations must accept that command style, or the
project must provide explicit custom commands. See
[chapter 16](16-portability-and-automation.md).

## 2.7 Check the installation

Use the help and version commands first:

```sh
rattbuild --help
rattpkg --help
rattsc --help
rattsc -e 'print("Rattscript is ready")'
```

For a source-checkout validation:

```sh
dub test --compiler=ldc2
./build/rattsc --test tests/script
./tests/integration/run.sh
```

The integration launcher defaults to LDC; set `DC=dmd` when using a DMD
application/library set. The pinned formatter/linter and unit/golden checks can
be run together with `sh tools/check.sh`.

If an executable fails before displaying a diagnostic, check shared-library
lookup and compiler-runtime availability. Application-level troubleshooting is
covered in [chapter 17](17-diagnostics.md).
