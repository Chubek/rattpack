# 23. Versioned release workflows

[Previous: Numeric reports](22-numeric-analysis.md) · [Contents](README.md) · [Next: Writing libraries](24-writing-rattscript-libraries.md)

The `semver` module provides strict version validation, precedence comparison,
stable ordering, and major/minor/patch increments. These operations can shape
construction-time metadata or run in standalone release tools. Each standalone
block below is a complete independent program.

## 23.1 Validate a complete version

```ratt
import "semver"

assert(semver.valid("1.2.3"))
assert(semver.valid("1.2.3-rc.1+build.7"))
assert(not semver.valid("v1.2.3"))
assert(not semver.valid("1.2"))
assert(not semver.valid("01.2.3"))
assert(not semver.valid("1.2.3-01"))
assert(semver.valid("1.2.3+01"))

let version = semver.parse("1.2.3-rc.1+build.7")
assert(version.major == 1 and version.minor == 2 and version.patch == 3)
assert(version.prerelease == "rc.1" and version.build == "build.7")
```

`valid` returns false for malformed strings; `parse` raises `E_RUNTIME` for the
same strings. Major/minor/patch components must fit Rattscript's signed 64-bit
integers. Numeric prerelease identifiers have no size limit and are compared
without converting them to machine integers.

The API requires a complete version without surrounding whitespace or a tag
prefix. Trim file text explicitly with `str.trim`. A Git tag may use `v` even
though the semantic version does not:

```ratt
import "semver"
import "regex" as re

let tag = "v1.2.3"
let match = re.find(tag, "^v(.+)$")
assert(match != nil and semver.valid(match[1]), "unexpected tag format")
let version = match[1]
assert(version == "1.2.3")
```

Keep the original tag when pinning the Git source; use the extracted version for
metadata and comparisons.

## 23.2 Understand precedence and build metadata

```ratt
import "semver"

let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
               "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
assert(semver.sort(ordered) == ordered)
assert(semver.compare("1.0.0-alpha.2", "1.0.0-alpha.10") == -1)
assert(semver.compare("1.0.0-2", "1.0.0-alpha") == -1)
assert(semver.compare("1.0.0", "1.0.0-rc.1") == 1)
assert(semver.compare("1.0.0+first", "1.0.0+second") == 0)
assert(semver.sort(["1.0.0+second", "1.0.0+first"]) ==
                  ["1.0.0+second", "1.0.0+first"])
```

Numeric prerelease identifiers compare numerically and precede nonnumeric ones.
A release follows prereleases of the same core version. Build metadata does
not contribute to precedence. Stable sorting preserves input order between
versions whose precedence is equal, including different build suffixes.

Equal precedence does not mean identical package content. Lockfile revisions
and tree hashes still identify exact dependency selections.

## 23.3 Select the newest stable candidate

```ratt
import "semver"
import "collections"

let candidates = ["2.0.0-rc.1", "1.2.9", "1.3.0", "1.3.0-beta.2"]
let stable = collections.filter(candidates, fn(value) {
  return semver.parse(value).prerelease == ""
})
assert(len(stable) > 0, "no stable candidate")
let selected = semver.sort(stable)[-1]
assert(selected == "1.3.0")

let compatible = collections.filter(stable, fn(value) {
  return semver.compare(value, "1.2.0") >= 0 and semver.compare(value, "2.0.0") < 0
})
assert(semver.sort(compatible)[-1] == "1.3.0")
```

This program expresses one explicit interval in ordinary Rattscript. Manifest
constraint expressions such as `^1.2` belong to the package resolver described
in [chapter 12](12-packages-and-lockfiles.md). `semver` operates on concrete
version strings and does not resolve dependencies or access a registry.

## 23.4 Increment the intended component

```ratt
import "semver"

assert(semver.bump("1.2.3") == "1.2.4")
assert(semver.bump("1.2.3", "minor") == "1.3.0")
assert(semver.bump("1.2.3", "major") == "2.0.0")
assert(semver.bump("1.2.3-rc.1+build.7") == "1.2.4")

let candidate = semver.parse("1.2.3-rc.1")
let promoted = str(candidate.major) + "." + str(candidate.minor) + "." + str(candidate.patch)
assert(promoted == "1.2.3")
```

`bump` increments the requested component, resets lower components, and removes
both suffixes. It is distinct from promoting a prerelease of the same core
version. Use the parsed components when that promotion is the intended operation.
Unknown parts or an increment beyond signed 64-bit bounds raise `E_RUNTIME`.

## 23.5 Generate release metadata from `VERSION`

Create a root `VERSION` file containing `1.2.3` followed by a newline. Complete
`Rattspec`:

```ratt
import "fs"
import "str" as text
import "semver"
import "json"

let release = text.trim(fs.read("VERSION"))
assert(semver.valid(release), "VERSION must contain a complete semantic version")
project(name: "release-metadata", version: release, kind: "single")

let parts = semver.parse(release)
let metadata = {name: "release-metadata", version: release,
                major: parts.major, minor: parts.minor, patch: parts.patch,
                prerelease: parts.prerelease, build: parts.build,
                next_patch: semver.bump(release)}
let output = rule(name: "metadata", output: "build/release.json", inputs: ["VERSION"])
action(output) { fs.write("build/release.json", json.stringify(metadata, pretty: true) + "\n") }
```

```sh
rattsc --lint Rattspec
rattbuild build metadata
```

This deliberately reads the version during construction: it determines both
project identity and the captured metadata. The read is permitted, and the
version file is explicitly tracked by the rule. A native spec reload captures
a changed version. A saved/exported graph retains its original metadata;
reconstruct/re-export it after editing `VERSION`. Strict frozen replay rejects
changed source bytes, as described in [chapter 25](25-hermetic-builds.md).

## 23.6 Coordinate project, package, and source pins

For a release, keep the root project version and the package's declared version
consistent. Git `tag:` values identify actual remote tags; registry `version:`
values express resolver constraints. A lockfile records the selected revision
and package tree, so changing a displayed version string does not update that
selection by itself.

An illustrative manifest fragment:

```ratt
package(name: "release-metadata", version: "1.2.3", license: "MIT")
deps {
  dep "helper" from: git("https://example.org/helper.git"), tag: "v2.0.0"
}
```

Replace the illustrative URL with the real dependency remote before resolving.
Use `rattpkg resolve` for resolution, `rattpkg verify` for locked tree checks, and
`resolve --update` only when requesting a fresh selection. Application and
library lockfile conventions remain those in chapter 12.

The next chapter packages these data-processing patterns as
[reusable Rattscript libraries](24-writing-rattscript-libraries.md).
