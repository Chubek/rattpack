# 13. Registries and archive formats

[Previous: Packages and lockfiles](12-packages-and-lockfiles.md) · [Contents](README.md) · [Next: Exporters](14-exporters.md)

## 13.1 Registry lookup protocol

A registry is an HTTP(S) base URL serving one JSON index per package name. For
dependency `demo`, the configured base:

```toml
[pkg]
registry = "https://packages.example.org"
```

produces this request:

```text
https://packages.example.org/demo/index.json
```

An index has a `versions` array:

```json
{
  "versions": [
    {
      "version": "1.2.3",
      "url": "https://packages.example.org/archives/demo-1.2.3.tar.gz",
      "sha256": "REPLACE_WITH_64_HEXADECIMAL_DIGITS"
    }
  ]
}
```

The checksum placeholder must be replaced before use. All three entry fields
are strings. The resolver expects a valid semantic version, a retrievable
archive URL, and a checksum of the archive's original bytes. The URL is used
verbatim; relative archive URLs are not resolved against the index location.

There is no package publishing API, registry authentication command, or search
endpoint required by this protocol. A static web server can serve indexes and
archives.

## 13.2 Version selection and transitive metadata

The resolver:

1. Collects requirements keyed by dependency name.
2. Visits unselected names in sorted order.
3. Filters registry candidates by all known constraints for that name.
4. Tries remaining candidates in descending semantic-version order.
5. Materializes each candidate and reads its `Rattpkg` dependencies, when present.
6. Backtracks if those requirements conflict with another selection.

Index order is not the priority rule; semantic version determines candidate
priority. Supply one unambiguous entry per version so publication does not
depend on equivalent-version duplicate ordering.

A registry package should contain a root `Rattpkg` whose `package(...,
version: ...)` matches the index entry. When that manifest is present, a version
disagreement is `E_PACKAGE`. Its dependencies provide transitive requirements.
An archive without a manifest can be treated as a project or raw source tree,
but it does not supply manifest-defined transitive dependencies.

## 13.3 Mirrors

```toml
[pkg]
registry = "https://primary.example.org"
mirrors = [
  "https://first-mirror.example.org",
  "https://second-mirror.example.org"
]
```

For each package index, the primary is tried first, then mirrors in configured
order if lookup/parsing raises an error. The first successfully read index is
used. Indexes are not merged, and a reachable but incomplete index does not
cause fallback merely because a preferred version is absent.

Mirror fallback is for **index lookup**. The chosen archive URL comes from that
index entry; it is not rewritten through each configured mirror if the download
fails. Publish suitable URLs in mirrored indexes.

Fetching an existing lock does not repeat registry-index selection. It uses the
already recorded archive URL/checksum or Git commit.

## 13.4 A small local registry

Prepare this layout outside the consumer's project:

```text
registry/
├── demo/index.json
└── archives/demo-1.2.3.tar.gz
```

The archive can contain one enclosing directory:

```text
demo-1.2.3/
├── Rattpkg
├── include/demo.h
└── src/demo.c
```

Its `Rattpkg` might be:

```ratt
package(name: "demo", version: "1.2.3", license: "MIT")
deps {
}
```

Calculate the archive checksum with a standard SHA-256 utility or Python:

```sh
python3 -c 'import hashlib,pathlib; print(hashlib.sha256(pathlib.Path("registry/archives/demo-1.2.3.tar.gz").read_bytes()).hexdigest())'
```

Insert that value into the JSON index and set its URL to
`http://127.0.0.1:8080/archives/demo-1.2.3.tar.gz`. Serve the directory:

```sh
python3 -m http.server 8080 --directory registry
```

In a separate terminal, configure the consumer's registry to
`http://127.0.0.1:8080`, declare `dep "demo" from: registry, version: "^1.2"`,
and run `rattpkg resolve`. Inspect the resulting lock, then run `rattpkg verify`.

The downloader also accepts `file://` URLs for local files. Use absolute paths
for reliable local archive/index fixtures. A local URL does not remove the
archive checksum requirement.

## 13.5 Archive recognition

Formats are recognized from bytes rather than filename extensions:

| Format | Implementation |
| --- | --- |
| ZIP | D standard-library ZIP reader |
| tar | In-tree 512-byte-header extraction |
| tar.gz / gzip-compressed tar | Pinned zlib bridge, then tar extraction |
| tar.xz / xz-compressed tar | Pinned xz/liblzma bridge, then tar extraction |

Renaming an unsupported compressed format to `.tar.gz` does not make it a
supported archive. There is no bzip2, Zstandard, 7-Zip, RAR, or general external
archive-tool fallback.

The tar reader handles regular files, directories, GNU long-name entries, and
path information in supported PAX headers. It checks tar header checksums,
entry sizes, and padding bounds. It is not a general preservation mechanism
for every tar metadata extension.

Compressed tar decoding uses bounded in-memory native buffers, with a maximum
of 1 GiB; xz decoding also applies a decoder memory limit. Downloads and archive
processing are memory-backed rather than streamed directly into filesystem
entries. Large or invalid compressed input can fail with `E_PACKAGE`.

## 13.6 Extraction paths and metadata

Archive entry names normalize backslashes for validation. Entries are rejected
when their names would escape the destination, including leading `/`, `..`
components, or colon-containing names. Parent directories are created as needed.

Regular files and directories are supported. Archive symlinks, hard links, and
special tar entry types are rejected. Git source trees are acquired through a
different mechanism and can contain symlinks represented in tree hashing.

After extraction, if the tree has exactly one top-level entry and that entry is
a directory, that enclosing directory becomes the package root. Archives with
multiple top-level entries keep their extraction root. Design archive layout so
the package manifest and source paths end up at the intended root.

Executable-bit presence is restored from supported tar/ZIP entry attributes on
POSIX/macOS. Rattpack does not preserve arbitrary ownership, ACLs, timestamps,
or every permission bit. The Windows backend does not model POSIX executable
permission bits as file metadata.

## 13.7 Two checksum layers

### Downloaded-byte SHA-256

The manifest/index checksum covers the original archive bytes. It is checked
before extraction. Recompressing identical files produces potentially different
archive bytes and therefore a different download checksum.

### Extracted-tree SHA-256

The package tree hash covers sorted normalized relative paths and entry
identity. Its inputs distinguish:

- Directory entries, including empty directories.
- Regular file contents, represented by file SHA-256 hashes.
- Presence of executable permission bits on backends that model them.
- Symlink targets for source trees that contain supported symlinks.

The tree representation uses length-framed fields before its final SHA-256
calculation. Root Git metadata is excluded. Timestamps do not determine tree
identity, and different package entry types are not conflated.

This is why editing a cached file, adding a generated file, removing an empty
directory, or changing executable-bit presence can fail verification. Tree
identity is backend-sensitive where executable/symlink representations differ;
do not assume every metadata-rich cached tree can be moved across operating
systems without revalidation.

## 13.8 Publication practices

For a reproducible registry package:

1. Include a matching-version `Rattpkg` at the final package root.
2. Use a supported archive format with regular files/directories.
3. Generate a SHA-256 for the exact distributed archive.
4. Publish an absolute archive URL and that checksum in the version entry.
5. Keep published version content and URLs stable.
6. Test resolution from a fresh cache and then `fetch` from the saved lock.

If a download becomes unavailable, a locked package already present in the
cache can still be verified and used. A missing cached package needs its locked
source to remain retrievable; index mirrors alone do not repair an unavailable
locked archive URL.
