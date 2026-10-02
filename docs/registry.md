# Registry protocol

`pkg.registry` and `pkg.mirrors` name HTTP(S) base URLs. For a dependency `foo`,
the resolver reads `<base>/foo/index.json`. Mirrors are tried in configured order
after the primary registry. An index has this shape:

```json
{
  "versions": [
    {
      "version": "1.2.3",
      "url": "https://registry.example.org/archives/foo-1.2.3.tar.gz",
      "sha256": "64-lowercase-hexadecimal-digits"
    }
  ]
}
```

Each archive contains a `Rattpkg` declaring the matching package version and its
transitive dependencies. A single enclosing directory is stripped. Versions
are tried in descending semantic-version order; the deterministic resolver
backtracks when transitive requirements conflict. Invalid ranges or unsatisfied
constraints produce `E_PACKAGE`.

The lock records the selected version, immutable source URL/Git commit,
download checksum, package identity (`package`, `project`, or `source`), direct
dependency names, and extracted-tree SHA-256. Tree identities include sorted
relative paths, file contents, directories, executable bits, and Git symlink
targets. Archive symlinks/hard links are rejected during extraction.

An unchanged manifest reuses its existing lock and cached content. `--update`
explicitly requests a fresh selection. `fetch` does not consult a registry index
or a floating branch when a lockfile already pins the package.
