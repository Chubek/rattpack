# spec-drift: TOML upstream moved to dlang-community

The dependency table originally named `https://github.com/Kripth/toml`, whose
tags stop at `v1.0.0-rc.3`. It does not contain the pinned DUB `toml` 2.0.1 commit
`8ce26af5064ae35e7a136ed454e5fd29f7c9f8af` (GitHub commit lookup returns 422).

The DUB registry's package metadata identifies the maintained repository as
`https://github.com/dlang-community/toml` and the same 2.0.1 commit. The manifest
and dependency table now use that upstream while retaining the exact pin.

Evidence: `https://code.dlang.org/api/packages/toml/info` and
`https://code.dlang.org/api/packages/toml/2.0.1/info`.

Recorded locally because this checkout has no Git remote/issue tracker configured.
