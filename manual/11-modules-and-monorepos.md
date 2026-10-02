# 11. Subordinate modules and monorepos

[Previous: Templates and profiles](10-templates-and-profiles.md) · [Contents](README.md) · [Next: Packages](12-packages-and-lockfiles.md)

## 11.1 Two meanings of module

Rattpack uses modules in two different ways:

- An **imported Rattscript module** is a helper source file returning namespaced
  functions and values. It is loaded with `import "./tools/helpers.ratt"`.
- A **subordinate build module** is a discovered `Rattspec.m` declaring targets
  as part of the containing project. It is loaded automatically by the spec
  loader, not by `import`.

Source modules are covered in [chapter 6](06-standard-library.md). This chapter
describes build identity and spec discovery.

## 11.2 Root discovery

The selected root must directly contain `Rattspec`, or `Rattspec.in` when the
non-template name is absent. The CLI does not search parent directories for a
root. Invoke from that root or pass `-C`.

After evaluating the root, the loader recursively examines subdirectories in
sorted order. It skips dot-prefixed directories, directories named `build`, and
symlink directories. It can pass through ordinary directories with no spec to
reach a deeper spec.

The loader looks for `Rattspec`/`Rattspec.in` or
`Rattspec.m`/`Rattspec.m.in` in each discovered directory. A directory containing
both root-style and subordinate-style specifications is an identity error.
Within either style, the ordinary name is preferred over the `.in` variant.

## 11.3 A multi-module project

Example layout:

```text
application/
├── Rattspec
├── src/main.c
└── codec/
    ├── Rattspec.m
    └── src/codec.c
```

Root `Rattspec`:

```ratt
project(name: "application", version: "1.0.0", kind: "multi-module")
import "target"
target.executable(name: "app", language: "c", sources: ["src/main.c"],
                  deps: ["codec::library"])
```

`codec/Rattspec.m`:

```ratt
module(name: "codec")
import "target"
target.library(name: "library", language: "c", sources: ["src/codec.c"])
```

The root target is `app`. The subordinate target is `codec::library`, and its
default output is `codec/build/liblibrary.a` on POSIX, because the declaration
is relative to the subordinate directory. The root executable's library
dependency is resolved after discovery; the subordinate spec need not be
evaluated before the root uses its qualified target name.

The root must have its own target. A subordinate module can organize deeper
modules without declaring a target itself.

## 11.4 Both subordinate markers are required

Subordinate identity requires:

1. The filename `Rattspec.m` (or its `.in` form).
2. A `module(name: ...)` declaration rather than `project(...)`.

Changing just the filename or just the call is insufficient. A subordinate
file calling `project` and a root-style file calling `module` both raise
`E_IDENTITY_MISMATCH`. Do not work around the check by importing the file.

The module name adds a namespace segment. A nested subordinate `module(name:
"formats")` beneath `codec` declares names such as
`codec::formats::parser`. Physical intermediate directory names without a spec
do not automatically add namespace segments. Choose module names that are
unique in the containing namespace.

Separate specs do not share their local Rattscript bindings. Refer to targets
across specs by qualified strings, and share declaration helpers through
ordinary source imports where appropriate.

## 11.5 Independent projects need a monorepo

A nested project with its own upstream identity is different from a subordinate
module. Declare it explicitly at the containing root:

```ratt
project(name: "workspace", version: "1.0.0", kind: "monorepo")
monorepo {
  member "apps/client"
  member "libs/math"
  vendored "third_party/codec"
  ignore "third_party/legacy"
}
import "fs"
let workspace = rule(name: "workspace", output: "build/workspace.txt")
action(workspace) { fs.write("build/workspace.txt", "workspace\n") }
```

Each `member` or `vendored` path must be inside the declaring project's
directory and contain a root-style spec. Paths are normalized before duplicate
member checks. `ignore` excludes a listed subtree from the declaring context's
discovery and can name a subtree that should not be evaluated.

Member directives require `kind: "monorepo"`. The `monorepo` brace section
groups the directives; it is not an imported file list or a source-language
namespace object.

## 11.6 Member and vendored identity

For a member `libs/math/Rattspec`:

```ratt
project(name: "math", version: "2.1.0", kind: "single")
import "target"
target.library(name: "library", language: "c", sources: ["src/math.c"])
```

The combined graph names that target `math::library`. The namespace uses the
member's declared project name, not its directory name and not the outer
workspace name. Its output remains rooted in `libs/math/build/`.

`member` identifies first-party membership; `vendored` records the intent to
preserve another project's identity. Both use independent project identity and
the same target-discovery mechanism. Vendoring does not automatically make
source directories read-only, download upstream sources, or resolve their
packages.

If a member itself contains subordinate modules, names continue underneath its
project namespace, for example `math::tests::check`. If it contains independent
nested projects, it should declare its own monorepo structure.

## 11.7 What happens to undeclared nested specs

If discovery finds a root-style spec that was not explicitly declared as a
member, it emits `W_UNDECLARED_NESTED_SPEC`. The loader assumes shared project
identity/resource conventions rather than treating the subtree as an
independent project.

This can produce target-name collisions, shared package lock lookup, and
serialized scheduling. The implementation marks affected existing and nested
contexts serial when it encounters this situation. Merely setting the outer
kind to `monorepo` without adding the member does not establish independence.

Use:

```sh
rattbuild build --warnings-as-errors
```

in CI so a newly vendored or accidentally nested project is caught immediately.
Resolve the warning according to the actual relationship:

- Convert a shared-identity subtree to `Rattspec.m` plus `module(...)`.
- Declare an independent project as `member` or `vendored` in a monorepo.
- Declare `ignore` when the subtree must not be loaded.

## 11.8 Package-lock lookup

`pkg.get` uses the current context's package root:

| Context | Lockfile used |
| --- | --- |
| Outer root | Outer `Rattpkg.lock` |
| Ordinary subordinate module | Its containing project's lockfile |
| Explicit member/vendored root | That member's `Rattpkg.lock` |
| Subordinate module inside an explicit member | The member's lockfile |
| Undeclared nested project sharing identity | The inherited package-root lockfile |

Resolve/fetch each independent package root before constructing the combined
build. `rattpkg` operates on one selected directory; it does not recursively
resolve all monorepo members in one invocation.

```sh
rattpkg resolve -C apps/client
rattpkg resolve -C libs/math
rattbuild build --warnings-as-errors
```

All package roots use the platform's content-addressed package cache. A combined
native build uses one graph/cache partition for its outer graph root; namespace
and per-context output directories provide project separation inside that graph.

## 11.9 Select targets across the workspace

```sh
rattbuild build math::library
rattbuild build client::app math::tests::check -j 8
rattbuild graph --dot -o workspace.dot
```

Root targets do not automatically receive the outer project-name prefix.
Qualified member/subordinate names are visible in the graph's actions and DOT
labels. If a dependency crosses project boundaries, specify its full qualified
name rather than relying on a local bare-name lookup.

Normal discovery is automatic and deterministic. Keep the identity markers
correct so that the graph can demonstrate independence instead of forcing
serial execution through an ambiguous nested project.
