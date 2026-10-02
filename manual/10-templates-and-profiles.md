# 10. Templates and initialization profiles

[Previous: Configuration](09-configuration.md) · [Contents](README.md) · [Next: Modules and monorepos](11-modules-and-monorepos.md)

## 10.1 The `.in` convention

A `.in` suffix identifies input to Rattscript's text preprocessor. Rendering
uses Rattscript expressions and emits a new string. It does not automatically
escape the result for C, TOML, JSON, shell, or Rattscript syntax.

There are several distinct uses:

| Context | When rendering happens | Where the result goes |
| --- | --- | --- |
| Initialization profile | During `rattbuild --init` | New root `Rattspec` |
| `Rattspec.in` / `Rattspec.m.in` | During graph construction | Evaluated as spec source in memory |
| Imported `.ratt.in` or standalone `.in` script | Before parsing that source | Evaluated/linted source in memory |
| `.in` file in `sources`, `inputs`, or `headers` | Text is rendered during construction; a generated action writes it during execution | File with final `.in` suffix removed |
| `fs.read("file.in")` | At the call's evaluation phase | Returned rendered string, without writing a file |
| `.in` file in `raw_inputs` | No automatic input-configuration rendering | Original bytes are tracked |

If both `Rattspec` and `Rattspec.in` exist at a root, discovery uses `Rattspec`.
The same preference applies to `Rattspec.m` over its `.in` form.

## 10.2 Expression substitutions

```text
Project: @{dirname}
Compiler: @{env.get("toolchain.c")}
Answer: @{6 * 7}
```

The expression between `@{` and its matching `}` is evaluated and converted to
display text. Multiple substitutions may appear on a line. Braces and quoted
strings inside the expression are recognized by the substitution scanner.
An individual substitution must close on the same physical line.

Template expression evaluation uses a separate construction-phase evaluator.
It has the normal language built-ins, configuration values, and the `env` module
bound automatically. Variables declared in the surrounding resulting script
are not template variables:

```ratt
# In a Rattspec.in, this let is source text produced by the template.
let answer = 42
# @{answer} cannot read that resulting script binding during preprocessing.
```

Use configuration or the template's own loop variables for substitutions.
Effectful calls are not allowed during rendering.

## 10.3 Available variables

Configured keys are exposed as nested maps as well as through `env.get`:

```text
@{toolchain.c}
@{env.get("toolchain.c")}
```

Extra variables depend on context:

| Variable | Initialization | Specs, imported scripts, `fs.read`, configured inputs |
| --- | --- | --- |
| `cwd` | Absolute project directory as a `path` | Evaluator/spec-context working directory as a `path` |
| `dirname` | Project directory basename | Context working-directory basename |
| `user` | User-name string, overriding the nested `user` map | Config-derived nested `user` map when its leaf settings exist |
| `date` | Current initialization date in `YYYY-MM-DD` form | No clock-derived extra variable |

For initialization metadata, `env.get("user.name")` works consistently even
though the initialization `user` extra is a string. In ordinary templates,
`user.name` can access the nested map. Importing a helper template does not
change the evaluator's filesystem working directory to the helper's location.

Clock-derived `date` is an initialization convenience; graph construction does
not provide it automatically. If reproducible date text is needed in a graph,
make it an explicit configuration value.

## 10.4 Conditional directives

Directives occupy a line of their own; surrounding indentation is accepted.

```text
@if env.get("build.mode", "debug") == "release"
#define APP_RELEASE 1
@else
#define APP_RELEASE 0
@end
```

`@if expression` uses ordinary Rattscript truthiness. `@else` is optional.
`@end` closes the conditional. Directive lines do not appear in the output;
ordinary emitted lines retain their line terminators and indentation.

Nested conditionals are supported. There is no dedicated `@elif` or
`@else if` directive; use a nested `@if` in an `@else` section. An unmatched
`@else`/`@end` or an unclosed section raises `E_TEMPLATE`.

## 10.5 Repetition

```text
@foreach feature in env.get("app.features", [])
Feature: @{feature}
@end
```

Each iteration binds the loop variable in the template evaluator. Expressions
inside that iteration can use it. As with the language's `for`, maps iterate
sorted keys and strings iterate Unicode characters. Lists preserve order.

Directives can nest:

```text
@foreach feature in env.get("app.features", [])
@if feature != "disabled"
Enabled: @{feature}
@end
@end
```

Unknown `@...` text is not a defined directive and is emitted as ordinary text
unless it begins one of the recognized forms. There is no general raw-block or
substitution-escape directive. Keep templates small and test their rendered
output when literal template-like text is required.

## 10.6 Configure a header for compilation

Save this as `include/settings.h.in`:

```c
#define APP_VERSION "@{env.get("app.version", "0.1.0")}"
@if env.get("app.trace", false)
#define APP_TRACE 1
@else
#define APP_TRACE 0
@end
```

Declare it as a tracked header:

```ratt
project(name: "configured", version: "1.0.0", kind: "single")
import "target"
target.executable(name: "configured", language: "c",
                  sources: ["src/main.c"],
                  headers: ["include/settings.h.in"],
                  include_dirs: ["include"])
```

The graph gains an internal configuration action. `rattbuild graph` computes the
rendered text but does not create `include/settings.h`. Execution writes that
file before compiling the executable. Changes in the template bytes or captured
settings affect the relevant recipes. The generated header is a declared graph
output and is removed by graph cleaning.

Reserve the `.in`-less filename for the generated result. Do not use it for a
hand-maintained file that an action would overwrite.

## 10.7 Read a template without generating its sibling

```ratt
project(name: "report", version: "1.0.0", kind: "single")
import "fs"
let report = rule(name: "report", output: "build/report.txt",
                  raw_inputs: ["report.txt.in"])
action(report) {
  fs.write("build/report.txt", fs.read("report.txt.in"))
}
```

The source template is tracked as original bytes. The action renders it with
its captured configuration, then writes only `build/report.txt`. No automatic
`report.txt` sibling action is inserted.

`fs.copy` and `fs.hash` operate on original file bytes. They do not have the
rendering behavior of `fs.read`.

## 10.8 Initialize a project

```sh
rattbuild --init
rattbuild --init --profile=cxx-exe
rattbuild --init --list-profiles
```

Initialization installs missing shipped profiles into the user profile
directory, chooses the requested profile, renders it, and atomically writes
`Rattspec` in the selected project directory. An existing `Rattspec` causes
`E_SPEC`; initialization is not a merge/update command.

The default profile is `empty`, which supplies a welcome-file rule so the root
remains a valid project. Compiled profiles generate only the spec, not source
files or header scaffolding.

## 10.9 Shipped profiles

| Name | Target | Source pattern |
| --- | --- | --- |
| `c-exe` | C executable named after the project directory | `src/**/*.c` |
| `c-lib` | Static C library | `src/**/*.c` |
| `cxx-exe` | C++ executable | `src/**/*.cpp` |
| `cxx-lib` | Static C++ library | `src/**/*.cpp` |
| `d-exe` | D executable | `src/**/*.d` |
| `d-lib` | Static D library | `src/**/*.d` |
| `monorepo` | Monorepo root with sample commented member directives and a welcome rule | No compiled sources |
| `empty` | Single-project welcome rule | No compiled sources |

These profiles start at version `0.1.0`. Extend the generated spec with explicit
header/input tracking, compiler flags, dependencies, and real member paths.
Other conventional source extensions require editing the generated pattern.

## 10.10 Add a custom profile

Profiles live under `<config-home>/rattpack/buildprof/`. On Windows this is
`%APPDATA%\rattpack\buildprof\`. A profile named `report` is `report.in`.

Example custom profile:

```ratt
project(name: "@{dirname}", version: "0.1.0", kind: "single")
import "fs"
let info = rule(name: "info", output: "build/info.txt")
action(info) {
  fs.write("build/info.txt", "Project: @{dirname}\nAuthor: @{user}\n")
}
```

Then initialize with:

```sh
rattbuild --init --profile=report
```

Profile names cannot contain path separators or be `.`/`..`. The loader reads
only the named file under `buildprof`; it does not accept an arbitrary template
path via `--profile`.

Existing profile files, including files using shipped names, are preserved when
missing profiles are installed. Updating Rattpack does not overwrite a locally
customized existing profile automatically.

## 10.11 Quoting and failures

Substitution is literal text insertion. For example, a configured name containing
a quote can make `project(name: "@{...}")` invalid Rattscript unless the template
handles that quote deliberately. The same applies to C string macros, shell
arguments, and other target languages. Restrict such values to the intended
format or design an explicit escaping transformation.

Unclosed substitutions and directive nesting errors are `E_TEMPLATE`.
Expression/parsing errors during rendering are generally wrapped as
`E_TEMPLATE`; a phase violation keeps `E_PHASE_VIOLATION`. Source locations may
refer to the template/generated evaluator program rather than exactly the final
output line. Inspect the original template and relevant config values when
troubleshooting.
