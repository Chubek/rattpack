# 3. Your first project

[Previous: Installation](02-installation.md) · [Contents](README.md) · [Next: Command line](04-command-line.md)

This tutorial builds a small C executable and then demonstrates target
selection, incremental checks, header tracking, and cleaning. It assumes
`rattbuild` is on `PATH` and the configured C compiler is available.

## 3.1 Create the source tree

Create a directory named `hello` with this layout:

```text
hello/
├── Rattspec
└── src/
    └── main.c
```

Save this as `src/main.c`:

```c
#include <stdio.h>

int main(void) {
    puts("hello from Rattpack");
    return 0;
}
```

Save this complete build description as `Rattspec`:

```ratt
project(name: "hello", version: "1.0.0", kind: "single")
import "fs"
import "target"

target.executable(
  name: "hello",
  language: "c",
  sources: fs.glob("src/**/*.c"),
  flags: ["-Wall", "-Wextra"]
)
```

`project` establishes the identity. `fs.glob` returns a sorted list of source
paths. `target.executable` declares an executable and obtains the compiler from
`toolchain.c`, whose default is `cc`. With no explicit output, the executable is
written to `build/hello`, or `build/hello.exe` on Windows.

## 3.2 Build and run

From the `hello` directory:

```sh
rattbuild build
./build/hello
```

The program prints:

```text
hello from Rattpack
```

The build reports the action it executes and a summary such as:

```text
build hello
1 built, 0 up to date
```

The compiler's output is also displayed when it produces any. On Windows,
invoke `build\hello.exe` using your shell's executable-path syntax.

The explicit command name is optional when no targets are specified:

```sh
rattbuild
```

When selecting targets, include `build`:

```sh
rattbuild build hello
```

The first positional argument is interpreted as the command, so `rattbuild
hello` is not shorthand for selecting the `hello` target.

## 3.3 Verify incrementality

Run the build again without modifying files:

```sh
rattbuild build
```

The expected summary is:

```text
0 built, 1 up to date
```

Now change the string in `main.c` and rebuild. The input-content identity
changes, so the executable is rebuilt. Deleting or changing the executable also
invalidates its native cache entry: outputs must exist and match their recorded
content for the action to be up to date.

The cache is separate from the `build/` directory. It normally lives under the
configured `build.cache_dir`, partitioned by project root.

## 3.4 Declare headers explicitly

Add `src/message.h`:

```c
#define HELLO_MESSAGE "hello through a header"
```

Change `main.c` to include it and use the macro:

```c
#include <stdio.h>
#include "message.h"

int main(void) {
    puts(HELLO_MESSAGE);
    return 0;
}
```

Add a field to the executable declaration:

```ratt
headers: fs.glob("src/**/*.h"),
```

For example, place it between `sources:` and `flags:`. Headers affect the
action's input hash but are not passed as separate compilation units. Rattpack
does not automatically parse compiler dependency files or `#include` statements;
this declaration makes header changes visible to incremental checks.

## 3.5 Inspect work before execution

Inspect the graph:

```sh
rattbuild graph --json -o graph.json
rattbuild graph --dot -o graph.dot
```

Neither command runs build actions. The DOT form can be rendered with an
external Graphviz installation:

```sh
dot -Tsvg graph.dot -o graph.svg
```

Preview a native build:

```sh
rattbuild build --dry-run
```

For stale actions, the preview prints `would build` instead of running commands.
Its final built count represents work it would perform. A dry run does not create
generated prerequisites, so it is an execution preview rather than a guarantee
that all execution-time reads will succeed.

## 3.6 Select the directory and parallelism

From the directory above `hello`:

```sh
rattbuild build -C hello -j 4
```

`-C` selects the project root. Relative source and output paths in the spec
remain relative to the spec's project/module directory. `-j 4` limits concurrent
actions to four; it does not split this single executable declaration into four
compilation actions.

If `-j` is omitted or zero, `build.jobs` is consulted. A configured value of zero
uses the logical CPU count.

## 3.7 Clean

```sh
rattbuild clean
```

Cleaning loads the graph, removes declared output artifacts, removes that
project's native/export cache directory, and removes its local `.rattpack/`
working directory. It does not indiscriminately delete all files under `build/`:
intermediate object files or unrelated files can remain.

The spec must still be valid when cleaning normally. If you have a saved graph,
you can clean its recorded outputs with `rattbuild clean --import graph.json`.

## 3.8 Generate the starting spec from a profile

In another new project directory, with sources already under `src/`:

```sh
rattbuild --init --profile=c-exe
```

This writes `Rattspec` using the directory basename as the project and target
name. It does not generate C source files. The profile discovers `src/**/*.c`,
so a compiled project with no matching source files fails at graph construction.

To try initialization without preparing compiler sources:

```sh
rattbuild --init
rattbuild build
```

The default `empty` profile is a small, valid project: its welcome rule writes
`build/welcome.txt`. See [chapter 10](10-templates-and-profiles.md) for profiles and
custom initialization templates.
