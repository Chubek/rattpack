# Dependency solving and repository discovery

## Satie integration

Rattpack builds `ratt-satie` from `third_party/satie`, using the
`stdplugin/DependencySAT` plugin. CMake needs a C++20 compiler. The helper is
installed beside the five applications by `tools/install.py`; keep it alongside
them when distributing a custom build. `librattpack` does not link C++.

Package resolution interns each distinct dependency requirement and candidate
before expanding its children, so cyclic package metadata reaches a fixed point.
It encodes required alternatives, conditional transitive requirements and
pairwise exclusion of conflicting versions/sources as SAT clauses. Candidate
discovery materializes the reachable alternatives to read their manifests.
Selection is deterministic: roots and children are discovered in manifest order,
with registry candidates considered newest first for each requirement. Satie
retains the first feasible preference at each step. Only the selected root
closure enters the lockfile, including mutually dependent packages exactly once.
Contradictions produce `E_PACKAGE` without replacing an existing lockfile.

Build dependencies have different semantics: every prerequisite must finish
before its consumer. A mandatory cycle has no valid schedule. `E_CYCLE` reports
the complete detected cycle, including implicit artifact-producer edges. For
cycles of up to 128 actions, guarded strict-order constraints let Satie suggest
an edge to review. The graph is not modified. Larger cycles still receive the
full cycle path without the quadratic SAT diagnostic encoding. A suggested
change breaks the reported cycle; other cycles may need their own changes.

The helper only processes local clauses. Build graph evaluation does not gain
network access. The separate Satie `PackageResolver` plugin chooses the highest
requested version without transitive constraints, so it is not used to decide
Rattpack package compatibility; the existing SemVer implementation supplies
version-range semantics to DependencySAT.

The reusable D entry point is `rattpack.constraints.solveConstraints`. It takes
integer CNF clauses and a list of variables to prefer true, and returns the
satisfiability result plus the chosen preferred variables. The helper's stdin
protocol is one space-separated preference list (possibly empty), followed by
one clause per line without DIMACS trailing zeroes. Output is `UNSAT`, or `SAT`
followed by each selected preferred variable on its own line. Empty clauses are
handled as false by the D adapter before invoking the plugin. Preference probes
keep earlier choices fixed; this is deterministic lexicographic selection, not
a claim of globally maximizing the number of selected variables.

## Generate a Rattpkg from a directory

```sh
python3 -m pip install -r tools/requirements.txt
python3 tools/ls2rattpkg.py ./libraries --name my-project --license MIT
```

The default output is `./libraries/Rattpkg`. The script scans immediate,
non-hidden subdirectories and `.a`, `.so` (including numeric version suffixes),
`.dylib`, `.dll`, and `.lib` files. Multiple binary formats of the same library
are deduplicated. It does not recursively interpret arbitrary source files.

Discovery uses a directory's own Git origin when present. Otherwise it imports
`tools/github-grep.py`, searches GitHub, and considers exact normalized name
matches in GitHub's star-ranked results, ignoring forks and archived repos.
Normalization ignores punctuation and an initial `lib`. When no usable GitHub
match is found (including API errors), the script queries DuckDuckGo through the
`ddgs` Python client and verifies matching repository links using `git ls-remote`.
Each dependency receives the remote's current HEAD commit as `rev:`. This pin
identifies the remote snapshot, not a version inferred from installed binaries
or uncommitted local files.

GitHub authentication is optional. Put credentials in the environment or `.env`:

```dotenv
GITHUB_TOKEN=your_token
```

`GH_TOKEN` and `GITHUB_API_KEY` are also accepted. Existing environment variables override values from
`.env`. Discovery starts at the current working directory; `--dotenv PATH`
selects another file. Tokens are sent in HTTP headers, never query strings.

```sh
# Search independently, with machine-readable output:
python3 tools/github-grep.py --name 'zlib in:name' --lang C --json

# Explicitly select an upstream when a name is ambiguous:
python3 tools/ls2rattpkg.py ./libraries --output ./Rattpkg \
  --repo zlib=https://github.com/madler/zlib --version 1.0.0 --license MIT
```

The script prints the chosen URL and revision for each dependency. Name matching
is heuristic; `--repo NAME=URL` selects a known upstream for an entry. Unresolved
libraries are listed as comments in the generated manifest and on stderr, with
exit status 1. A complete result exits 0. Existing files are preserved unless
`--force` is passed. The default package version is `0.1.0` and the default
license is `NOASSERTION`.

Offline tool regressions: `python3 -m unittest discover -s tests/tooling`.
