# 19. Practical recipes

[Previous: Development](18-development.md) · [Contents](README.md) · [Next: Collection pipelines](20-collection-pipelines.md)

Each recipe is an independent pattern. A complete `Rattspec` shown below belongs
at its own project root; fragments should be adapted to an existing declaration
rather than combined by repeating `project(...)` in one file.

## 19.1 Copy a tracked input with an atomic write

Project files: `Rattspec` and `data/message.txt`.

```ratt
project(name: "copy", version: "1.0.0", kind: "single")
import "fs"
let copy = rule(name: "copy", output: "build/message.txt",
                inputs: ["data/message.txt"])
action(copy) {
  fs.write("build/message.txt", fs.read("data/message.txt"))
}
```

```sh
rattbuild build copy
rattbuild build copy
```

The second unchanged build skips the action. `fs.write` creates parent
directories and replaces the output atomically. If byte copying rather than
text/template processing is desired, use `fs.copy` in the action.

## 19.2 Generate a version header before compiling

Create `VERSION` containing `1.0.0` and a trailing newline. Create `src/main.c`:

```c
#include <stdio.h>
#include "version.h"

int main(void) {
    puts(APP_VERSION);
    return 0;
}
```

Complete `Rattspec`:

```ratt
project(name: "versioned", version: "1.0.0", kind: "single")
import "fs"
import "str" as text
import "target"

let header = rule(name: "version-header", output: "build/version.h",
                  inputs: ["VERSION"])
action(header) {
  let version = text.trim(fs.read("VERSION"))
  fs.write("build/version.h", "#define APP_VERSION \"" + version + "\"\n")
}

target.executable(name: "versioned", language: "c", sources: ["src/main.c"],
                  headers: ["build/version.h"], include_dirs: ["build"],
                  deps: [header])
```

The version is read during execution and tracked through the rule input. The
compiler target consumes the generated header, and the graph orders its producer
before compilation. Use version text appropriate for a C string; this example
does not implement arbitrary C escaping.

## 19.3 Make object-level incremental work explicit

The automatic executable target compiles all sources in one action. For a flat
`src/` directory with distinct C basenames, separate object rules can provide
finer-grained native execution:

```ratt
project(name: "objects", version: "1.0.0", kind: "single")
import "fs"
import "path"
import "toolchain"

let cc = toolchain.discover("c")
let headers = fs.glob("include/**/*.h")
let object_paths = []
let object_targets = []

for source in fs.glob("src/*.c") {
  let name = path.stem(source)
  let output = "build/objects/" + name + ".o"
  let object = rule(name: "object_" + name, output: output,
                    inputs: [source] + headers,
                    command: [cc.command, "-Iinclude", "-c", source, "-o", output],
                    toolchain: cc.fingerprint)
  object_paths.append(output)
  object_targets.append(object)
}

rule(name: "app", output: "build/app" + toolchain.executable_suffix,
     deps: object_targets,
     command: [cc.command] + object_paths +
       ["-o", "build/app" + toolchain.executable_suffix],
     toolchain: cc.fingerprint)
```

Each object is an action, and linking depends on their outputs. If using nested
source directories, derive unique object/target names from more than the basename.
Track per-source headers more narrowly when appropriate; this example deliberately
tracks all listed headers for every object.

## 19.4 Run an executable test and create a success stamp

Create `src/main.c` that prints the expected text and returns zero. Put the exact
expected output, including its final newline, in `tests/expected.txt`.

```ratt
project(name: "tested", version: "1.0.0", kind: "single")
import "target"
import "path"
import "proc"
import "fs"

let app = target.executable(name: "app", language: "c", sources: ["src/main.c"])
let tests = rule(name: "tests", output: "build/tests.ok", deps: [app],
                 inputs: ["tests/expected.txt"])
action(tests) {
  let result = proc.run([path.absolute(app.output)])
  assert(result.output == fs.read("tests/expected.txt"), "unexpected program output")
  fs.write("build/tests.ok", "passed\n")
}
```

```sh
rattbuild build tests
```

The root-context `app.output` path resolves correctly with `path.absolute`.
For a subordinate/member context, use a context-local or explicitly absolute
executable path rather than assuming graph-relative handles are local paths.

The stamp is written only after the checked process and assertion succeed.
It allows normal incremental skipping. This recipe tests changes in tracked
inputs; it is not an always-run test facility. Remove the stamp or clean to
request another unchanged run.

## 19.5 Select debug/release flags from config

Configuration:

```toml
[build]
mode = "release"
```

Complete C project spec:

```ratt
project(name: "modes", version: "1.0.0", kind: "single")
import "env"
import "toolchain"
import "target"
let mode = env.get("build.mode", "debug")
target.executable(name: "app", language: "c", sources: ["src/main.c"],
                  flags: toolchain.flags(mode) + ["-Wall"])
```

`build.mode` is custom configuration read by this spec. The helper yields `-O2`
for `release` and `-g` otherwise. Edit/load config before construction; an existing
export retains the old captured flags until re-exported.

For several named configurations, use separate XDG config directories or an
explicit project convention. `--profile` is for initialization, not runtime
debug/release profile selection.

## 19.6 Render a package template outside the package cache

Assume the fetched package `assets` contains `message.txt.in` at its root.

```ratt
project(name: "assets", version: "1.0.0", kind: "single")
import "pkg"
import "path"
import "fs"
let assets = pkg.get("assets")
let template = path.join(assets.path, "message.txt.in")
let message = rule(name: "message", output: "build/message.txt",
                   raw_inputs: [template])
action(message) {
  fs.write("build/message.txt", fs.read(template))
}
```

The package source is tracked without generating a sibling inside its cache
tree. `fs.read` renders with the action's captured settings, and the output goes
to the consumer's `build/` directory. Run package fetch/verify before building.

## 19.7 Run a tracked Python generator

Create `tools/generate.py`:

```python
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
destination.write_text(source.read_text().upper())
```

Create `data/input.txt`, then use:

```ratt
project(name: "generator", version: "1.0.0", kind: "single")
import "proc"
let python = proc.which("python3")
if not python { python = proc.which("python") }
assert(python, "Python 3 is required")
rule(name: "generated", output: "build/output.txt",
     inputs: ["tools/generate.py", "data/input.txt"],
     command: [python, "tools/generate.py", "data/input.txt", "build/output.txt"])
```

Tracking the script prevents a generator-code change from being missed. The
scheduler creates the output parent before the command runs. The argv list
avoids implicit shell interpretation, including for filenames containing spaces.

If the tool needs several checked invocations, replace the single `command:`
with an action using `proc.run` calls. Write a declared output after the required
steps finish.

## 19.8 Combine a C library and a C++ application

With `src/value.c` exporting `int value(void)` and `src/main.cpp` declaring it
using `extern "C"`:

```ratt
project(name: "mixed", version: "1.0.0", kind: "single")
import "target"
let value = target.library(name: "value", language: "c", sources: ["src/value.c"])
target.executable(name: "app", language: "cxx", sources: ["src/main.cpp"],
                  deps: [value], flags: ["-std=c++17"])
```

The dependency orders the library build and supplies its output to the C++
link command. Match the language linkage in source; Rattpack's target dependency
does not rewrite C++ declarations or propagate header search paths.

## 19.9 Verify a graph round trip

```sh
rattbuild graph --json -o .graphs/original.json
rattbuild graph --dot -o .graphs/project.dot
rattbuild graph --import .graphs/project.dot --json -o .graphs/restored.json
```

Compare the JSON documents semantically, for example:

```sh
python3 -c 'import json,pathlib; a=json.loads(pathlib.Path(".graphs/original.json").read_text()); b=json.loads(pathlib.Path(".graphs/restored.json").read_text()); assert a == b; print("identical graph")'
```

Keep source/config/tool state unchanged between the first two graph captures.
The dot-prefixed storage directory is omitted from normal discovery/globs. The
DOT payload, rather than only the displayed edges, makes reimport lossless.

## 19.10 Resolve a local Git source for development

A consuming `Rattpkg` can use an absolute local Git remote with a real tag:

```ratt
package(name: "consumer", version: "1.0.0", license: "MIT")
deps {
  dep "library" from: git("/absolute/path/to/library-repository"), tag: "v1.0.0"
}
```

```sh
rattpkg resolve
rattpkg verify
```

The result is a cached checked-out source tree, not a live link to the working
repository. Uncommitted changes are not the tagged tree. A new selection requires
a new pin or deliberate update; branch use additionally requires floating
resolution opt-in.

This pattern is useful for testing package manifests and source layouts before
publishing archives/indexes. It still uses normal lock/tree verification, so
build generated files in the consumer's output directory rather than mutating
the cache.

## 19.11 Export after validating the native graph

```sh
rattsc --lint Rattspec
rattbuild build --warnings-as-errors
rattbuild export --to=ninja -o build/export/ninja
ninja -C build/export/ninja
```

Native execution first validates tracked work and outputs. Export then captures
the graph for the external scheduler. Build-system freshness policies differ;
re-export when recipes, configuration, helpers, or discovered source lists
change. The generated project continues to require the recorded Rattpack host
and referenced source paths.

For larger Rattscript-only generators, continue with the new walkthroughs:
[collection pipelines](20-collection-pipelines.md),
[structured records and text](21-structured-data-and-text.md),
[numeric reports](22-numeric-analysis.md), and
[release metadata](23-versioned-release-workflows.md). Each includes a complete
program or tracked action that can be adapted into a project.
