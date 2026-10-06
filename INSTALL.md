# INSTALL — Rattpack

How to build Rattpack from source and install the binaries.

For design rationale and contributor rules, see `AGENTS.md`.
For full detail, see `manual/02-installation.md`. The quick path below
mirrors `README.md` → Build and test.

## 1. Prerequisites

| Requirement | Purpose | Minimum / notes |
|---|---|---|
| DUB | Bootstrap builds, pinned D deps | any recent release |
| LDC (`ldc2`) or DMD (`dmd`) | Compile D runtime + CLIs | LDC is the default; plugins must match host compiler family/major |
| C compiler + linker (`cc`), C++20 compiler | Native bridge, BLAKE3, libgit2, zlib, xz, Satie helper | — |
| CMake | Configure native-library build | 3.20+ |
| Git | Checkout + pinned submodules | — |
| Python 3 | Build helpers (`tools/*.py`), manpage staging | 3.x; 3.11+ required for integration tests (`tomllib`) |
| OpenSSL dev headers/libs (POSIX) | Link native/runtime deps | e.g. `libssl-dev` on Debian/Ubuntu |
| cmake, ninja, make, meson | Integration tests only | — |

Optional: Bubblewrap (POSIX sandbox), `sandbox-exec` (macOS sandbox).

## 2. Prepare the checkout

From the repo root:

```sh
git submodule update --init --recursive
```

`third_party/` entries (libgit2, zlib, xz, blake3, satie, openaipp) are
pinned submodules — do not substitute system copies when reproducing
the build. D package pins live in `dub.selections.json`; Git mirrors
are declared in `Rattpkg`.

## 3. Bootstrap build

LDC (default):

```sh
dub build -c rattbuild --compiler=ldc2
./build/rattbuild build --warnings-as-errors
```

The first command builds `librattpack` + `rattbuild`. The second is the
self-hosted (dogfood) build: it evaluates the root `Rattspec` and builds
the shared runtime, all CLIs (`rattbuild`, `rattpkg`, `rattsc`,
`rattspec`, `ratt-language-server`), the `ratt-satie` helper, and manpages.

Individual bootstraps:

```sh
dub build -c rattpkg --compiler=ldc2
dub build -c rattsc --compiler=ldc2
dub build -c rattspec --compiler=ldc2
dub build -c ratt-language-server --compiler=ldc2
```

DMD (use consistently for runtime, apps, and plugins):

```sh
dub build -c rattbuild --compiler=dmd
./build/rattbuild build --warnings-as-errors   # after setting toolchain.d=dmd (see below)
```

The self-hosted build reads its D compiler from `toolchain.d` in the
Rattpack config. For a DMD dogfood build set:

```toml
[toolchain]
d = "dmd"
```

`DC` selects the compiler for repo helpers only (does not rewrite config):

```sh
DC=dmd python3 tools/dogfood.py plugins
```

Build products land in `build/`:

| Product | Linux | macOS | Windows |
|---|---|---|---|
| CLIs | `rattbuild`, `rattpkg`, `rattsc`, `rattspec`, `ratt-language-server` | same | `*.exe` |
| Shared runtime | `librattpack.so` | `librattpack.dylib` | `rattpack.dll` |
| Solver helper | `ratt-satie` | `ratt-satie` | `ratt-satie.exe` |

Linux uses `$ORIGIN` rpath, macOS `@loader_path` — keep the CLIs and the
shared runtime in the same directory. The OS loader must also find the
compiler's shared D runtime and system libs.

## 4. Install

The installer (`install.sh` → `tools/install.py`, stdlib only) copies a
relocatable layout: binaries + runtime to `<prefix>/bin`, manpages to
`<prefix>/share/man/man1`, and `profiles/`, `templates/`, `manual/`,
`docs/`, `addons/`, `README.md`, `LICENSE` to `<prefix>/share/rattpack/`.

```sh
./install.sh                              # installs to ~/.local, builds must exist in build/
./install.sh --prefix /path/to/prefix
./install.sh --build                       # dub-bootstrap all CLIs first (repo build/ only)
./install.sh --build --compiler=dmd
./install.sh --with-plugins                # also install cmake/gnumake/ninja/meson + assist plugins to bin/plugins
./install.sh --dry-run                     # preview copy plan, writes nothing
./install.sh --destdir /staging --prefix /usr  # package staging
```

On Windows run `python tools/install.py` with the same flags (`.exe`/`.dll`
naming handled automatically).

Then put the prefix on `PATH`:

```sh
# POSIX sh
export PATH="$HOME/.local/bin:$PATH"
rattbuild --version; rattpkg --version; rattsc --version; rattspec --version
```

```powershell
# PowerShell
$env:Path = "$HOME\.local\bin;" + $env:Path
rattbuild --version
```

Manpages: `man rattbuild` (also `rattpkg`, `rattsc`, `rattspec`,
`ratt-language-server`); for a non-standard prefix:
`man -M /path/to/prefix/share/man rattbuild`.

`rattspec assist` additionally needs the assist plugin (`--with-plugins`
installs to `bin/plugins/`) and OpenCode V2 on `PATH` for the
`--opencode` backend.

## 5. Verify

```sh
rattbuild --help
rattpkg --help
rattsc --help
rattsc -e 'print("Rattscript is ready")'
```

Source-checkout validation:

```sh
dub test --compiler=ldc2
./build/rattsc --test tests/script
./tests/integration/run.sh              # needs cmake, ninja, make, meson; DC=dmd for a DMD set
sh tools/check.sh                       # tooling unit tests + pinned dfmt/dscanner + unit/golden tests
```

## 6. Platform notes

- **POSIX:** ensure `cc`, `c++`, CMake, and the D compiler are on `PATH`;
  install OpenSSL dev package. Bubblewrap is used opportunistically for
  action sandboxing.
- **macOS:** install a C toolchain, CMake, Python, and the D compiler. Links
  Security + CoreFoundation + `iconv`. XDG-style config/cache locations,
  same as POSIX.
- **Windows:** use a compiler/linker environment matching the D compiler and
  CMake generator. The DUB pre-build step invokes `python`, so that name
  must resolve to Python 3. C/C++ target lowering emits GCC/Clang-style
  options — the toolchain must accept them or the project must use explicit
  custom `command:` rules.

## 7. Troubleshooting

| Symptom | Check |
|---|---|
| Executable fails before printing a diagnostic | Shared-library lookup: is `librattpack` beside the binary? Is the compiler's shared D runtime + OpenSSL visible to the loader? (`ldd build/rattbuild`, `otool -L`, `dumpbin /dependents`) |
| Native-build errors (missing headers, CMake failures) | Submodules initialized? C/C++ compilers + CMake 3.20+ on `PATH`? OpenSSL dev package installed? |
| `DC=...` had no effect on project builds | Expected: `DC` only drives repo helpers; project builds use `toolchain.d` from `Config.toml`. |
| Integration tests fail on TOML | Python 3.11+ required (`tomllib`). |
| Plugins rejected with `E_PLUGIN_ABI` | Rebuild the plugin with the same D compiler family/major as the host. |

Application-level diagnostics (all `E_*`/`W_*` codes) are catalogued in
`docs/diagnostics.md` and `manual/17-diagnostics.md`.
