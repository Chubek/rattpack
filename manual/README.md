# Rattpack Manual

This manual describes the **Rattpack 0.1.0 development line**: the `rattbuild`
build system, the `rattpkg` package manager, the `rattsc` interpreter, and their
shared Rattscript language. It covers installation, everyday use, the public
scripting surface, and extension development.

The examples and option descriptions follow the implementation shipped in this
repository. Shell examples use a POSIX shell unless labeled otherwise. Commands
such as `rattbuild` assume the repository's `build/` directory is on `PATH`; while
working in the source checkout, `./build/rattbuild` is equivalent.

## Current development coverage

The manual includes the eleven additional embedded libraries recorded under
**Unreleased** in [`CHANGELOG.md`](../CHANGELOG.md): `list`, `dict`, `sets`,
`iter`, `functional`, `math`, `stats`, `json`, `regex`, `base64`, and `semver`.
Chapter 6 is their API reference; chapters 20–24 develop complete workflows
around them. The interpreter still identifies this development line as 0.1.0.

The build chapters also describe the current ready-action thread pool, captured
process environments, graph format v2, and strict `--hermetic` execution.
Chapter 25 connects these features in a reproducible-build walkthrough.

## Contents

| Chapter | Subject |
| --- | --- |
| [1. Overview and core concepts](01-overview.md) | Components, the project lifecycle, construction and execution, terminology |
| [2. Installation and building from source](02-installation.md) | Prerequisites, LDC/DMD bootstrap, shared libraries, platform setup |
| [3. Your first project](03-first-project.md) | A complete C project, initialization, building, incrementality, cleaning |
| [4. Command-line reference](04-command-line.md) | Every public command and option for all three applications |
| [5. The Rattscript language](05-rattscript.md) | Values, expressions, statements, functions, closures, annotations, built-ins |
| [6. Modules and standard library](06-standard-library.md) | Imports and the complete shipped module API |
| [7. Projects, targets, and native compilation](07-projects-and-targets.md) | Project declarations, target fields, C/C++/D lowering, dependencies |
| [8. Actions, graphs, and incremental builds](08-actions-and-graphs.md) | Deferred actions, tracked inputs, scheduling, caches, graph interchange |
| [9. Configuration](09-configuration.md) | Config locations, TOML/YAML, defaults, custom keys, read-only access |
| [10. Templates and initialization profiles](10-templates-and-profiles.md) | `.in` processing, substitutions, directives, supplied and custom profiles |
| [11. Subordinate modules and monorepos](11-modules-and-monorepos.md) | Discovery, identity, namespaces, vendoring, member package scopes |
| [12. Packages and lockfiles](12-packages-and-lockfiles.md) | Manifests, resolution, source types, fetching, verification, dependency use |
| [13. Registries and archive formats](13-registries-and-archives.md) | Registry protocol, mirrors, extraction, checksums, tree identities |
| [14. Exporting to other build systems](14-exporters.md) | CMake, GNU Make, Ninja, Meson, frozen configuration, re-exporting |
| [15. Extensions, plugins, and embedding](15-extensions-and-embedding.md) | Rattscript extensions, D ABI, plugin loading, programmatic interfaces |
| [16. Portability and automation](16-portability-and-automation.md) | Backend behavior, path conventions, subprocess scopes, CI workflows |
| [17. Diagnostics and troubleshooting](17-diagnostics.md) | Exit statuses, all diagnostic codes, practical recovery procedures |
| [18. Development and implementation guide](18-development.md) | Repository map, test suites, dependency policy, internal architecture |
| [19. Practical recipes](19-recipes.md) | Generated files, test targets, configurable builds, package integration |
| [20. Collection pipelines](20-collection-pipelines.md) | Lists, maps, set algebra, eager iteration, callback composition |
| [21. Structured data and text processing](21-structured-data-and-text.md) | JSON reports, regex captures, Base64, tracked data transformations |
| [22. Numeric analysis and build reports](22-numeric-analysis.md) | Checked arithmetic, statistics, quantiles, numeric validation |
| [23. Versioned release workflows](23-versioned-release-workflows.md) | SemVer precedence, version selection, release metadata, tracked version files |
| [24. Writing and maintaining Rattscript libraries](24-writing-rattscript-libraries.md) | Reusable modules, API contracts, action captures, embedding, golden tests |
| [25. Hermetic builds and frozen graphs](25-hermetic-builds.md) | Explicit environments/tools, strict file access, graph replay, backend support |

## Suggested reading paths

- **New users:** chapters 1–3, then chapters 7–10.
- **Existing projects adopting Rattpack:** chapters 4, 7, 8, 11, and 12.
- **Rattscript authors:** chapters 5, 6, 8, 10, and 20–24.
- **Package maintainers:** chapters 9, 12, 13, and 23.
- **Build-system integrators:** chapters 8, 14–16, and 25.
- **Contributors:** chapters 15, 18, and 24, together with [`AGENTS.md`](../AGENTS.md).

For a hands-on progression through the expanded library, read chapters 20–23
in order: shape collections, exchange structured data, compute reports, then
attach version metadata. Chapter 24 turns those operations into reusable
modules; chapter 25 gives their build actions explicit reproducibility contracts.

## Conventions

`Rattspec`, `Rattspec.m`, `Rattpkg`, and `Rattpkg.lock` are case-sensitive
conventional filenames. A Rattscript code block is either a complete file when
identified as such or a fragment to insert into an existing file. Dependency
URLs under `example.org` are illustrative. A checksum or revision placeholder
must be replaced with a real value before resolving dependencies.

API signatures in this manual use `name(arg, optional: default) -> result` as
documentation notation. Actual Rattscript accepts positional arguments and
named arguments of the form `name: value`; it has no special signature notation
at call sites.

Each chapter links back to this contents page and to adjacent chapters. The
shorter guides in [`docs/`](../docs/) remain useful as quick references.
