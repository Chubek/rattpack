# 12. Packages and lockfiles

[Previous: Modules and monorepos](11-modules-and-monorepos.md) · [Contents](README.md) · [Next: Registries and archives](13-registries-and-archives.md)

## 12.1 Responsibilities of `rattpkg`

`rattpkg` resolves dependency source trees and maintains a verified package
cache. It does not automatically compile dependencies, install headers into a
system prefix, or inject compiler flags into a build. A `Rattspec` decides how
to consume fetched sources through `pkg.get`.

Resolution is intentionally separate from building. `rattbuild` does not
download packages when it sees a missing dependency. Prepare the lock/cache
first, then construct the graph.

## 12.2 The manifest

Save a package declaration and dependencies in the exact filename `Rattpkg`:

```ratt
package(name: "application", version: "1.0.0", license: "MIT")

deps {
  dep "compression" from: registry, version: "^1.3"
  dep "formatting" from: git("https://example.org/formatting.git"), tag: "v2.0.0"
}
```

The URLs and registry package names here are examples; supply actual sources.
The manifest is Rattscript evaluated in construction phase. It can import
helpers, read config, and compute declarations deterministically. Standard
construction-phase effect restrictions apply.

`package(name:, version:, license:)` is required exactly once. `name` and
`version` are strings; `license` defaults to `MIT` when omitted. Names must be
nonempty and consist only of ASCII letters, digits, `_`, `-`, and `.`. The names
`.` and `..` are invalid. The same validation applies to dependency names.

`deps { ... }` groups declarations. A dependency name can be declared once in
one manifest. The global source values/functions are `registry`, `git(url)`,
`http(url)`, and `ftp(url)`.

## 12.3 Dependency fields

| Field | Meaning |
| --- | --- |
| Dependency name | Local dependency key, used by the resolver/cache and `pkg.get` |
| `from` | Source map produced by `registry`, `git`, `http`, or `ftp` |
| `version` | Registry version constraint; defaults to `*` |
| `tag` | Git tag pin |
| `rev` | Git revision pin, preferably a full commit identity |
| `branch` | Git branch reference requiring floating-resolution opt-in |
| `sha256` | Mandatory 64-hex-digit downloaded-byte checksum for HTTP/FTP |

Normal syntax is:

```ratt
dep "name" from: SOURCE, field: VALUE
```

For multi-line declarations, put a comma before the continued named field,
as in the archive example below. Use the directive form at statement level:
`dep` is recognized specially there, so a normal-looking `dep("name", ...)`
statement is not interchangeable with this syntax.

## 12.4 Registry dependencies

```ratt
dep "compression" from: registry, version: "^1.3"
```

The resolver reads `<pkg.registry>/<name>/index.json`, considers valid semantic
versions satisfying the requested ranges, and tries candidates in descending
version order. Transitive `Rattpkg` requirements are included. It backtracks
when a candidate's transitive requirements conflict.

The constraint implementation is the pinned `semver` package. Typical inputs
include `*`, exact versions, and caret/tilde ranges. Prefer an unambiguous
constraint supported by that parser; invalid constraints are `E_PACKAGE`.
`version:` on a non-registry source does not replace the explicit Git/archive
content pin or turn that source into a registry query.

Only one selected content/version exists for each dependency name in a
resolution. This is not a multi-version, per-dependent package installation
model. Incompatible requirements on the same name must be reconciled or the
resolution fails.

See [chapter 13](13-registries-and-archives.md) for the index schema and archive
version rules.

## 12.5 Git dependencies

Exactly one of `tag`, `rev`, or `branch` is required:

```ratt
dep "library" from: git("https://example.org/library.git"), tag: "v1.2.0"
```

or, with a real commit in place of the placeholder:

```ratt
dep "library" from: git("https://example.org/library.git"), rev: "FULL_COMMIT_ID"
```

The Git fetcher clones the remote, resolves the selected commit, checks out its
tree with detached HEAD, records that commit, and removes the checkout's `.git`
directory before caching the source tree. Fetching from a lock uses the recorded
commit rather than reselecting a tag or branch.

Git transport is provided through the pinned libgit2 backend; SSH support uses
the configured native library's OpenSSH execution support. Normal remote/auth
configuration must be available to that environment. Use full remote URLs or
absolute local-repository paths for predictable local-fixture behavior.

This release does not perform an additional recursive Git-submodule update for
package checkouts. If dependency sources rely on submodules, arrange a source
distribution containing the required files or handle that acquisition explicitly
outside ordinary package consumption.

### Floating branches

```ratt
dep "library" from: git("https://example.org/library.git"), branch: "main"
```

Fresh resolution requires:

```sh
rattpkg resolve --allow-floating
```

The resulting lock still pins an exact commit. Reusing or fetching that lock
does not follow the branch. To move to its newly resolved head:

```sh
rattpkg resolve --update --allow-floating
```

`--allow-floating` is an explicit resolution choice, not a switch that makes
every subsequent build use the latest remote content.

## 12.6 HTTP and FTP dependencies

```ratt
dep "archive" from: http("https://example.org/archive-1.0.0.tar.xz"),
  sha256: "REPLACE_WITH_64_HEXADECIMAL_DIGITS"
```

The placeholder is deliberately not a valid checksum. Replace it with the
SHA-256 of the actual archive bytes. FTP uses the same requirement:

```ratt
dep "legacy" from: ftp("ftp://example.org/pub/legacy.tar.gz"),
  sha256: "REPLACE_WITH_64_HEXADECIMAL_DIGITS"
```

The parser requires exactly 64 hexadecimal digits and normalizes letter case.
Downloaded bytes are checked before extraction. The extracted tree receives a
separate content hash; archive-byte identity and tree identity are not the same.

Supported formats are tar, gzip-compressed tar, xz-compressed tar, and ZIP.
Extraction rejects escaping paths and unsupported link/special entries. A
single enclosing directory is stripped when materializing an archive package.

## 12.7 Identity of a fetched source tree

Rattpack inspects the package root in this order:

1. A `Rattpkg` marks a package and provides its version/transitive dependencies.
2. A `Rattspec` without `Rattpkg` marks a project-derived source package. The
   manager inspects a direct `project` declaration's named literal version; it
   does not evaluate the project's build graph.
3. Without either conventional file, the dependency is a raw source tree.

The lock's `identity` field records the categories `package`, `project`, or
`source`. These are categories, not a renamed local dependency key. `pkg.get`
uses the dependency name declared by the consuming manifest.

A registry-selected package manifest must agree with the selected version.
For a source without usable version metadata, the manager uses a tag, recorded
Git revision, or `0.0.0` as appropriate. A project-only source need not contain
valid compiler inputs to be fetched: project synthesis is metadata inspection,
not a build.

Automatic source inspection uses the exact filenames `Rattpkg` and `Rattspec`.
A remote containing only a template-form spec is not equivalent to this
project-metadata inspection path.

## 12.8 Resolve, fetch, verify

### Resolve

```sh
rattpkg resolve
```

Resolution computes a manifest fingerprint from source and evaluated package/
dependency declarations. If a matching lock exists, it reuses it and checks or
fetches its content. Otherwise it performs a deterministic new selection and
atomically writes the lock after success. Candidate downloads may populate the
cache while the resolver explores alternatives.

Even an otherwise harmless source edit, such as a manifest comment, contributes
to the source fingerprint and can cause fresh resolution. The existing lock is
not reused solely because dependency spelling appears unchanged.

### Update

```sh
rattpkg resolve --update
```

This requests a fresh selection explicitly. Review the new lock before
committing it, particularly when registry candidates or Git tags changed.

### Fetch

```sh
rattpkg fetch
```

Fetch reads the lockfile only. It verifies existing cached trees and retrieves
missing ones from the locked URL/commit, then compares the resulting tree hash
with the lock. It does not consult registry indexes to choose versions.

### Verify

```sh
rattpkg verify
```

Verify reads the lock and re-hashes each package tree. A missing or changed tree
fails. It does not fetch or repair content.

## 12.9 Cache layout and lockfile contents

Package trees live at:

```text
<cache-home>/rattpack/pkgs/<dependency-name>/<tree-hash>/
```

Temporary resolution directories live under `<cache-home>/rattpack/tmp/` and
are cleaned up after the acquisition attempt. `build.cache_dir` does not change
this package-cache layout.

`Rattpkg.lock` is TOML, with these top-level keys:

| Key | Meaning |
| --- | --- |
| `lock_version` | Format version, currently `1` |
| `project` | Consuming package name |
| `manifest_hash` | Fingerprint of the manifest source and evaluated declarations |
| `[[package]]` | One table per resolved dependency |

Each package table contains `name`, `version`, `source`, `url`, `revision`,
`sha256`, `tree_hash`, `identity`, and a `dependencies` list. Unused source-specific
string fields are written as empty strings. Registry selections are lowered to
their concrete archive source (`http`) in the lock. Entries and dependency-name
lists are sorted for deterministic output.

Commit the lockfile for applications. Library packages normally leave it out so
consumers can resolve their own compatible requirements. Treat the generated
lock as the reproducible selection artifact rather than hand-editing hashes to
silence verification failures.

## 12.10 Consume a dependency in a spec

```ratt
project(name: "consumer", version: "1.0.0", kind: "single")
import "pkg"
import "path"
import "target"

let library = pkg.get("library")
let implementation = target.library(
  name: "library-build", language: "c",
  sources: [path.join(library.path, "src/library.c")],
  headers: [path.join(library.path, "include/library.h")],
  include_dirs: [path.join(library.path, "include")]
)
target.executable(name: "consumer", language: "c", sources: ["src/main.c"],
                  headers: [path.join(library.path, "include/library.h")],
                  include_dirs: [path.join(library.path, "include")],
                  deps: [implementation])
```

This example assumes that layout in the package tree. Outputs go in the
consumer's build directory, preserving the cached source tree. The package
handle exposes only `path` and `version` as supplied lookup fields; there is no
automatic package build-target registration.

`pkg.get` checks existence, not full tree integrity. Run package verification
where required before building. Avoid writing generated files into a cached
package: changes, including extra files, invalidate its tree identity. If a
dependency needs configured `.in` resources, render them to the consumer's
output directory instead of automatically configuring a sibling inside the
cache.

In a monorepo, resolve each independent package root and use its own lockfile,
as described in [chapter 11](11-modules-and-monorepos.md).
