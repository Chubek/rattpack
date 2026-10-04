# 25. Hermetic builds and frozen graphs

[Previous: Writing libraries](24-writing-rattscript-libraries.md) · [Contents](README.md)

Strict `--hermetic` execution combines frozen input/tool identities with declared
file access and process environments. The expanded pure libraries make many
generators possible entirely inside Rattscript. This chapter starts with that
portable path, then describes external tools and graph replay.

## 25.1 Ordinary sandboxing and strict execution

Ordinary sandboxed actions have interpreter write-root checks and backend-dependent
subprocess restrictions. Strict actions additionally enforce their recorded
execution contract:

| Contract | Strict behavior |
| --- | --- |
| Source files | Original source bytes must match the graph's frozen hashes |
| Rattscript reads | Reads must name declared inputs or outputs; symlink traversal is rejected |
| Rattscript writes | Writes must name declared outputs rather than arbitrary siblings in an output directory |
| External programs | Executables must be registered action tools and still match their recorded hashes |
| Process environment | Sandboxed execution uses captured defaults plus explicit target overrides |
| Action mode | `sandbox: false` is rejected |

Failures use `E_HERMETIC`. `--hermetic` is a build/graph/export CLI option; the
public target fields used below are `inputs`, `tools`, `env`, and `sandbox`.
The resulting DAG records strict flags on actions.

## 25.2 Build a pure Rattscript report strictly

Create `data/samples.json`:

```json
{"samples_ms":[10,20,30]}
```

Complete root `Rattspec`:

```ratt
project(name: "strict-report", version: "1.0.0", kind: "single")
import "fs"
import "json"
import "stats"
import "proc"

let report = rule(name: "report", output: "build/report.json",
                  inputs: ["data/samples.json"], env: {REPORT_MODE: "release"})
action(report) {
  let document = json.parse(fs.read("data/samples.json"))
  let samples: list = document.samples_ms
  let result = {count: len(samples), mean_ms: stats.mean(samples),
                mode: proc.env("REPORT_MODE")}
  fs.write("build/report.json", json.stringify(result, pretty: true) + "\n")
}
```

```sh
rattsc --lint Rattspec
rattbuild build report --hermetic -j 2
rattbuild build report --hermetic -j 2
```

The result has count 3, mean 20 ms, and mode `release`. No subprocess is launched:
`proc.env` reads the captured action map, and the data is processed by embedded
libraries. Strict file checks therefore work without a subprocess isolation
utility. The second unchanged invocation skips the successful output.

The input and output are named exactly in the declaration. Writing an ancillary
`build/detail.json` would require its own modeled output; ordinary directory-scoped
write permission does not authorize that extra file in strict mode.

## 25.3 Make process values explicit

The platform supplies these construction-time defaults:

| Variable | Captured default |
| --- | --- |
| `PATH` | Construction process's program search path |
| `LANG`, `LC_ALL` | `C` |
| `TZ` | `UTC` |
| `SOURCE_DATE_EPOCH` | `0` |
| Win32 system variables | Available `SystemRoot`, `WINDIR`, `COMSPEC`, `PATHEXT` |

The target's `env:` map extends/overrides the defaults. The graph stores that map,
and changing an explicit value changes action identity. For a config-driven value,
this fragment belongs in a spec importing `env`, `fs`, and `proc`:

```ratt
let mode = env.get("build.mode", "debug")
let configured = rule(name: "configured", output: "build/mode.txt", env: {MODE: mode})
action(configured) { fs.write("build/mode.txt", proc.env("MODE") + "\n") }
```

`env.get` reads captured Rattpack configuration. `proc.env` reads the captured
process map in a sandboxed action; it remains forbidden during construction.
Backend temporary-directory variables are supplied to subprocesses separately.
Standalone and unsandboxed execution read ambient process values instead.

## 25.4 Save and replay a strict graph

With the report project unchanged:

```sh
rattbuild graph --hermetic --dot -o .graphs/report.dot
rattbuild graph --import .graphs/report.dot --json -o .graphs/report.json
rattbuild build --import .graphs/report.json
```

The strict action flags survive conversion and import; a second `--hermetic`
flag is not needed to preserve them. Relative CLI graph paths are resolved from
the shell's current directory. The graph retains the original project root and
working directories.

Current graph JSON has `version: 2`; DOT carries canonical JSON in a
`// rattpack-v2:` Base64 payload. Import checks recorded identities and producer
relationships. Earlier graph-format versions must be recaptured with a compatible
current runtime rather than edited into apparent compatibility.

Save the following standalone inspection program as root `inspect-graph.ratt`:

```ratt
import "fs"
import "json"
import "iter"

let graph = json.parse(fs.read(".graphs/report.json"))
assert(graph.version == 2)
let report = iter.find(graph.actions, fn(action) { return action.name == "report" })
assert(report != nil)
assert(report.hermetic == true)
assert(report.environment.REPORT_MODE == "release")
print(report.name, report.hermetic, report.environment.REPORT_MODE)
```

```sh
rattsc inspect-graph.ratt
```

The output is `report true release`. Captured library helpers execute from
restored code/scopes, with matching native primitives registered by the runtime.
The original `Rattspec` is not required for replay, but declared inputs, recorded
tools, and the compatible runtime remain required.

## 25.5 Handle intentional input changes

Editing `data/samples.json` after graph capture makes strict imported execution
fail with `E_HERMETIC: frozen graph input changed`. The graph is a statement about
specific input bytes, not just paths. To accept an intentional new dataset,
reconstruct the graph from the specs:

```sh
rattbuild graph --hermetic --json -o .graphs/report.json
rattbuild build --import .graphs/report.json
```

A fresh native `rattbuild build --hermetic` also loads the current specs and
captures current source hashes before executing. Generated inputs are supplied
through their producers and checked during execution. Strict actions additionally
verify that declared input content did not change during the action.

Use `--dry-run` to inspect prospective native work. It still performs applicable
frozen input/tool validation and does not produce missing generated inputs.

## 25.6 Declare external programs

For an external generator, create `data/message.txt` containing `hello` and a
newline, and `tools/upper.py`:

```python
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
destination.write_text(source.read_text().upper())
```

Use a separate project for this generator. Before constructing its graph, find
the concrete Python executable path on the POSIX host:

```sh
python3 -c 'import os,sys; print(os.path.realpath(sys.executable))'
```

Add the reported path to the selected `Config.toml`, for example the following
with the path replaced by the one present on your machine:

```toml
[toolchain]
python = "/usr/bin/python3.11"
```

`toolchain.python` is a custom configuration key used by this spec. Concrete
regular-file paths avoid strict Bubblewrap mounts onto executable symlink aliases.
The complete spec is:

```ratt
project(name: "strict-generator", version: "1.0.0", kind: "single")
import "proc"
import "env"

let python = proc.which(env.get("toolchain.python", "python3"))
assert(python, "Python 3 is required")
rule(name: "generated", output: "build/message.txt",
     inputs: ["tools/upper.py", "data/message.txt"], tools: [python],
     command: [python, "tools/upper.py", "data/message.txt", "build/message.txt"])
```

On a POSIX backend with working strict Bubblewrap support:

```sh
rattbuild build generated --hermetic
```

`tools:` resolves and hashes the Python executable during construction. The
script is an input file, not the executable tool. Strict execution checks both
the input bytes and the executable's recorded content. Executables in a recorded
`command:` are also registered by lowering, so this example's explicit tool list
documents an identity that lowering already discovers.

For programs invoked only by an action-body `proc.run`, declare `tools:` explicitly.
Deferred actions additionally capture available configured C/C++/D compiler
tools. When using strict POSIX subprocess execution, those recorded tools also
need concrete file paths rather than symlink aliases; configure the toolchain
paths accordingly before graph capture.

## 25.7 Backend support and output staging

| Backend | Strict subprocess path |
| --- | --- |
| POSIX | Requires working Bubblewrap; isolates namespaces and exposes trusted system roots, declared inputs/tools, and staged output directories |
| macOS | Strict subprocess execution currently raises `E_HERMETIC` |
| Win32 | Strict subprocess execution currently raises `E_HERMETIC` |

POSIX strict subprocesses see trusted tool/runtime roots such as `/usr`, `/bin`,
and library directories. Project input files and tools are mounted read-only.
Output directories are staged under the action temporary directory; successful
declared regular-file outputs are copied back to the project. The temporary
directory also supplies the subprocess home/config/cache locations.

Ordinary sandboxed execution has the fallbacks described in chapter 16. Strict
execution reports unavailable or failed isolation instead of falling back to
ordinary subprocess behavior. Pure Rattscript actions use interpreter checks
and do not enter this subprocess path.

## 25.8 Export the same contract

```sh
rattbuild export --hermetic --to=ninja -o build/export/ninja
ninja -C build/export/ninja
```

The exported graph carries strict action metadata into the frozen runner.
Outer schedulers still decide when to invoke work using their own freshness
rules, as described in [chapter 14](14-exporters.md); strict checks apply when
the runner validates/executes an action. Recapture and re-export after changing
frozen inputs, environment values, helper recipes, or tool identities.

Together, explicit data contracts, reusable pure helpers, tracked inputs, and
frozen execution settings connect the standard-library workflows in chapters
20–24 to Rattpack's build graph.
