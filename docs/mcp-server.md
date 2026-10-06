# Rattpack MCP server

`tools/rattpack-mcp.py` is a Model Context Protocol server that scans a
directory and generates the two Rattpack root files: `Rattspec` (build spec)
and `Rattpkg` (package manifest). It needs only the Python standard library;
dependency discovery reuses `tools/ls2rattpkg.py` and `tools/github-grep.py`,
so GitHub authentication and the DuckDuckGo fallback from
[dependency solving](dependency-solving.md#generate-a-rattpkg-from-a-directory)
apply unchanged.

## Running

Serve MCP on stdio (configure your client to run this command):

```sh
python3 tools/rattpack-mcp.py
```

One-shot mode generates files directly and prints a JSON summary, which is
also how the server is smoke-tested:

```sh
python3 tools/rattpack-mcp.py ./my-project --name my-project --exclude src
```

Example client configuration (OpenCode `opencode.json`):

```json
{"mcp": {"rattpack": {"type": "local",
  "command": ["python3", "/path/to/rattpack/tools/rattpack-mcp.py"]}}}
```

## Tools

| Tool | Effect |
| --- | --- |
| `scan_directory` | Inventory source files, library candidates, nested `Rattspec` files, and suggested language/target. Writes nothing. |
| `search_github` | Repository search by name, optionally filtered by language. |
| `generate_rattpkg` | Write a pinned `Rattpkg` for a directory of libraries. Unresolvable entries become `# Unresolved library:` comments. |
| `generate_rattspec` | Write a `Rattspec` matching the scanned source layout (C/C++/D, exe vs. lib via `main` detection, monorepo members from nested specs). |
| `generate_project` | Scan once, then write both files with a shared project name and version. |

`generate_rattpkg` and `generate_project` accept `exclude` (e.g. `["src"]`)
because library discovery treats every immediate subdirectory as a
dependency candidate, including source roots. Use `repo` (`NAME=URL`) to pin
an ambiguous library to a known upstream. Existing files are never replaced
unless `force` is set.

Offline regressions: `python3 -m unittest discover -s tests/tooling -p 'test_mcp.py'`.
