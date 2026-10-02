# 16. Portability and automation

[Previous: Extensions and embedding](15-extensions-and-embedding.md) · [Contents](README.md) · [Next: Diagnostics](17-diagnostics.md)

## 16.1 Backend model

Rattpack's internal `rt.sys` interface selects a POSIX, macOS, or Win32 backend.
The backend supplies configuration/cache homes, user identity, CPU count,
program lookup, dynamic-library loading, output suffixes, and subprocess
execution restrictions.

The script-visible `toolchain.platform` values are `posix`, `macos`, and `win32`.
POSIX is a backend family rather than a distribution name. Do not use it to
infer that every machine has the same compiler version or shell utilities.

## 16.2 Portable paths and arguments

Use `path.join` and `path.normalize` for path operations. Prefer relative paths
in a project's spec so the source description can be loaded in another checkout.
Constructed/exported graphs still record absolute roots and working directories.

```ratt
import "path"
import "toolchain"
let output = path.join("build", "checker" + toolchain.executable_suffix)
```

Explicit executable outputs should add the platform suffix when appropriate.
Automatic executable targets already do so. Shared suffixes are exposed by
`toolchain.shared_suffix`; static-library suffixes are chosen by the automatic
library declaration logic.

Keep command arguments in lists:

```ratt
command: ["python3", "tools/generate.py", "an input with spaces.txt", "build/out.txt"]
```

Each entry is one argument. Do not insert shell quotation marks around an
argument merely because its path contains spaces. `proc.run` and native recorded
commands do not invoke a shell by default.

Python names vary by platform. For portable construction-time discovery:

```ratt
import "proc"
let python = proc.which("python3")
if not python { python = proc.which("python") }
assert(python, "Python 3 is required")
```

The project is responsible for choosing a program with the required semantics;
discovery of a name alone does not validate its version.

## 16.3 Compiler command conventions

The native C/C++ lowering uses `-I`, `-c`, `-o`, `-shared`, and `-fPIC`, plus `ar`
for static libraries. This fits GCC/Clang-style drivers. It is not a complete
translation to MSVC's `cl`/`link`/`lib` syntax.

On a Windows setup requiring different syntax, supply custom rules or an action
that calls the appropriate compiler tools. Add source/header inputs and explicit
toolchain identity. Use an output filename with the intended Windows suffix.

D lowering uses DMD/LDC-style source flags and `-of=`. Compiler-specific shared
runtime/library options remain the project's responsibility. The repository's
own helpers handle runtime/plugin linkage specially; those details are not
automatically attached to every user target.

Compiler discovery uses configured names or paths. Configuration strings are
not split into shell commands, so put wrapper logic in an actual executable
instead of a value such as `"wrapper compiler"`.

## 16.4 Action filesystem scopes

The scheduler creates declared output directories and a temporary directory at:

```text
<graph-root>/.rattpack/sandbox/<action-id>/
```

With sandboxing enabled, Rattscript filesystem mutations are checked against
the declared output directories. Writes traversing symlinks or normalized paths
outside those directories fail with `E_ACTION`.

Subprocess restrictions depend on the backend:

| Backend | Subprocess behavior |
| --- | --- |
| POSIX | Probe Bubblewrap (`bwrap`); when usable, bind the system read-only and declared output/temp directories writable |
| macOS | Use `sandbox-exec` when found, with write access limited to output/temp subpaths |
| Win32 | Run the process with action-specific `TEMP`/`TMP`; no equivalent OS-enforced write filter is installed |

If Bubblewrap is absent or its probe fails, POSIX falls back to direct subprocess
execution. macOS also runs directly when `sandbox-exec` is absent. Rattscript
write-root checks still apply when the action's `sandbox` field is true, but a
directly executed external program is not constrained by those interpreter
checks.

These mechanisms do not provide a general network-isolation or fully hermetic
environment promise. Model action inputs and explicit configuration so builds
remain explainable even when tools can read other system state.

## 16.5 Environment and temporary files

Sandboxed POSIX/macOS subprocess execution supplies the action temporary path
as `TMPDIR` and sets `PYTHONDONTWRITEBYTECODE=1`. Win32 supplies `TEMP` and `TMP`.
The temporary directory is removed after the action attempt. Other process
environment values normally remain available through the process layer.

When `sandbox: false`, the scheduler runs the process directly rather than
using that sandboxed-process wrapper. Do not assume the same temporary-variable
overrides apply to an unsandboxed action.

`proc.env` can read process environment during execution/standalone mode, but
ambient values are not part of the native cache key automatically. For a value
that determines graph recipes or should trigger rebuilding, put it in config
and capture it through `env.get` during construction.

## 16.6 Parallel resource ownership

Action write scopes are directory scopes. Two actions with outputs in one
directory can still collide if they both create the same undeclared intermediate
file. Make output and intermediate names unique, or create a dependency that
orders genuinely shared resource use.

The native scheduler limits concurrency through `-j`/`build.jobs`. Independent
monorepo identities allow normal scheduling, while undeclared nested-project
fallback can mark work serial. Exported schedulers use their own concurrency
options and emitted dependencies.

Separate top-level build processes using the same checkout/outputs are not
automatically serialized by a project-lock CLI facility. CI jobs should use
separate working trees/output locations when executing concurrently.

## 16.7 A CI workflow for an application

Assume Rattpack and the project's toolchain are installed, and the application
commits a valid `Rattpkg.lock`:

```sh
set -eu
rattsc --lint Rattspec
rattpkg fetch
rattpkg verify
rattbuild build --warnings-as-errors -j 4
rattbuild graph --dot -o .ci-artifacts/graph.dot
```

Lint checks annotations; graph construction/build checks project identity,
source existence, compiler discovery, dependencies, and outputs. Fetch fills
missing locked content; verify confirms it before consumption. An application
without managed packages can omit the package commands.

For a library package that does not commit a lock, the CI job must perform
resolution before fetching/building:

```sh
rattpkg resolve
rattpkg verify
rattbuild build --warnings-as-errors
```

That job's selection can change when allowed registry versions change. Retain
its generated lock as a job artifact when reproducibility of a particular run
matters.

## 16.8 Cache use in CI

Graph cache entries partition by absolute graph-root text and include recipes,
toolchain fingerprints, inputs, and output hashes. Restoring a graph cache does
not recreate outputs: missing outputs are rebuilt. Changing checkout paths can
change the partition and identities.

Package cache trees are content-addressed and useful across consuming projects.
Treat them as source content, not mutable build directories. After restoring a
package cache, `rattpkg verify` detects corruption/extra files as well as missing
entries. Preserve relevant executable/symlink metadata when archiving caches.

Use absolute XDG config/cache locations for isolated POSIX/macOS jobs, as in
[chapter 9](09-configuration.md). Windows homes are selected through the backend's
`APPDATA`/`LOCALAPPDATA` environment values.

## 16.9 Automation scripts

Standalone Rattscript is useful for tool orchestration:

```ratt
import "proc"
import "fs"
let result = proc.run(["python3", "tools/check.py"], check: false)
assert(result.code == 0, "checks failed")
fs.write("build/check-summary.txt", result.output)
```

Save it as a source file and run with `rattsc FILE`. Its working directory is
the script file's directory, so a root automation script can use project-relative
paths predictably. Unlike a deferred build action, standalone execution does not
receive output-write restrictions or incremental caching automatically.

For automation whose result is part of the build, declare a tracked rule and
run the script/tool from its action. [Chapter 19](19-recipes.md) shows stamp and
generated-file patterns.
