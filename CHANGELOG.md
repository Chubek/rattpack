# Changelog

## Unreleased

- Implement Vim, Neovim, and Sublime Text add-ons with canonical filename and
  template detection, syntax highlighting, indentation, and editor linting.
- Add `ratt-language-server` with UTF-16 document synchronization, static
  diagnostics/import analysis, completion, hover, definitions, and symbols;
  include the server and editor packages in source builds and installation.
- Join running scheduler workers before returning from a failed build, and
  discard queued work during cleanup.
- Keep D compiler intermediate objects in the target output directory so
  sandboxed library builds can write them.
- Add eleven embedded Rattscript standard-library modules: `list`, `dict`,
  `sets`, `iter`, `functional`, `math`, `stats`, `json`, `regex`, `base64`, and
  `semver`, including deterministic JSON output and action-serializable helpers.
- Add `rattspec` and the `opencode-assist` plugin: `rattspec assist 'REQUEST'`
  creates and updates `Rattspec` and `Rattpkg` through OpenCode V2's HTTP API,
  with model selection, timeouts, host-side validation before writing, and the
  new `E_ASSIST` diagnostic.

## 0.1.0 — 2026-10-02

- Initial Rattscript interpreter, portable runtime, build graph, package manager,
  versioned plugin interface, first-party exporters, and project profiles.
- Bootstrap dependency and native-library pins recorded in `dub.selections.json`
  and Git submodules.
