# Changelog

## Unreleased

- Use the vendored Satie DependencySAT plugin in a standalone C++20 helper for
  deterministic package constraint solving, compatible package cycles, and
  build-cycle ordering repair suggestions. Keep the shared runtime D-only.
  Add a native-only plugin-host build option to the vendored Satie header.
- Add `tools/ls2rattpkg.py` for pinned Git manifests from library directories,
  with GitHub search, `.env` authentication and DuckDuckGo repository fallback.

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
- Add the `openai-assist` plugin and `rattspec assist --openai`, reaching any
  OpenAI-compatible server through the vendored `third_party/openaipp` client.
  The C++20 bridge is linked only into that plugin, so the shared runtime does
  not require a C++ toolchain. Supports bearer keys and HTTP basic credentials
  across both `/chat/completions` and `/responses`.
- Launch OpenCode with `--standalone` for assist, so a request never waits on or
  is redirected by the shared background service.
- Add `Rattpack.json` tooling configuration under the configuration directory,
  resolving backend, endpoint, credential, plugin, script, and command settings
  from command-line flags, then the environment, then the file.
- Add memory-mapped file support to the platform backends and a directory map
  module: `rattspec map DIRECTORY` caches a binary map under
  `.cache/rattpack/<directoryname>.bin` and can print a terse map DSL that
  `assist` attaches to requests. Adds the `E_MAP` diagnostic.

## 0.1.0 — 2026-10-02

- Initial Rattscript interpreter, portable runtime, build graph, package manager,
  versioned plugin interface, first-party exporters, and project profiles.
- Bootstrap dependency and native-library pins recorded in `dub.selections.json`
  and Git submodules.
