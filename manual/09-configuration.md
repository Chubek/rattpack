# 9. Configuration

[Previous: Actions and graphs](08-actions-and-graphs.md) · [Contents](README.md) · [Next: Templates and profiles](10-templates-and-profiles.md)

## 9.1 Configuration locations

Rattpack loads a user-level configuration from a directory named `rattpack`
under the platform's configuration home.

| Platform | Configuration home | Default configuration filename |
| --- | --- | --- |
| POSIX | `$XDG_CONFIG_HOME`, or `$HOME/.config` when unset | `<home>/rattpack/Config.toml` |
| macOS | `$XDG_CONFIG_HOME`, or `$HOME/.config` when unset | `<home>/rattpack/Config.toml` |
| Windows | `%APPDATA%` | `%APPDATA%\rattpack\Config.toml` |

`Config.yaml` in the same directory is an accepted alternative. If both files
exist, TOML wins and the loader produces `W_DUAL_CONFIG` through its warning
sink. `rattbuild` displays this warning and can promote it with
`--warnings-as-errors`. The package/interpreter CLIs use the same precedence,
but do not install the build CLI's configuration-warning display sink.

Missing configuration is normal: the defaults below are used. There is no
project-local config-file search, config-file CLI override, or layered merge of
TOML and YAML. `-C` selects a project, not a different user config location.

## 9.2 Default settings

| Key | Default | Interpretation |
| --- | --- | --- |
| `user.name` | `$USER` on POSIX/macOS; `%USERNAME%` on Windows; `unknown` fallback | Initialization metadata |
| `user.email` | Empty string | Available for custom profiles/scripts |
| `user.license` | `MIT` | Available for custom profiles/scripts |
| `toolchain.c` | `cc` | C compiler executable |
| `toolchain.cxx` | `c++` | C++ compiler executable |
| `toolchain.d` | `ldc2` | D compiler executable |
| `build.jobs` | `0` | Zero means logical CPU count |
| `build.cache_dir` | `<cache-home>/rattpack` | Native/export graph cache base |
| `pkg.registry` | `https://pkgs.example.org` | Illustrative registry URL; configure an actual registry before using registry dependencies |
| `pkg.mirrors` | Empty list | Additional registry-index base URLs |

On POSIX/macOS, cache home is `$XDG_CACHE_HOME`, falling back to `$HOME/.cache`.
On Windows, it is `%LOCALAPPDATA%`, falling back to the configuration home.

Defaults are loaded first. Configured leaf keys replace those values; arbitrary
additional leaf keys are retained for scripts and profiles.

## 9.3 TOML example

Save this as the selected configuration file, adjusting tool names and URLs to
your environment:

```toml
[user]
name = "Jane Doe"
email = "jane@example.org"
license = "MIT"

[toolchain]
c = "clang"
cxx = "clang++"
d = "ldc2"

[build]
jobs = 8
cache_dir = "~/.cache/rattpack"
mode = "release"

[pkg]
registry = "https://packages.example.org"
mirrors = ["https://mirror.example.org"]

[project_defaults]
warnings = ["-Wall", "-Wextra"]
```

The application recognizes `build.jobs` and `build.cache_dir` directly.
`build.mode` and `project_defaults.warnings` in this example are custom keys:
they affect a graph only when the spec or a profile reads them. Merely defining
a build mode does not automatically add compiler flags.

Toolchain values should be executable names or executable paths, not shell
command strings such as `"ccache clang"`. For wrapper use, provide a wrapper
executable that can accept the compiler arguments and a predictable `--version`
query.

## 9.4 YAML equivalent

```yaml
user:
  name: Jane Doe
  email: jane@example.org
  license: MIT
toolchain:
  c: clang
  cxx: clang++
  d: ldc2
build:
  jobs: 8
  cache_dir: "~/.cache/rattpack"
  mode: release
pkg:
  registry: https://packages.example.org
  mirrors:
    - https://mirror.example.org
```

YAML's document root must be a mapping. Typed scalars and sequences are converted
to Rattscript values. Nested mappings are flattened into dotted lookup keys,
as TOML tables are.

## 9.5 Reading keys in Rattscript

```ratt
import "env"
import "target"
import "toolchain"

let mode = env.get("build.mode", "debug")
let warnings = env.get("project_defaults.warnings", ["-Wall"])
target.executable(name: "app", language: "c", sources: ["src/main.c"],
                  flags: toolchain.flags(mode) + warnings)
```

The snippet belongs after a root `project(...)` declaration. `env.get` returns
the configured leaf value or its fallback; without an explicit fallback, an
unknown key returns `nil`. `env.has` tests key existence, including configured
keys whose value is `nil`.

Flattening means `env.get("user.name")` is defined while `env.get("user")`
normally is not a nested-table query. Template evaluation additionally provides
nested maps for convenient expressions such as `toolchain.c`; ordinary specs
use the `env` API.

Collections returned by `env.get` are recursively copied. Local appends or map
updates do not mutate the stored configuration. There is no `env.set` API.

## 9.6 Build parallelism precedence

The native scheduler selects its job count in this order:

1. A nonzero `-j` / `--jobs` value.
2. A nonzero configured `build.jobs` value.
3. The backend's logical CPU count.

`-j 0` does not override a nonzero configured job count; it asks for the normal
configuration-based choice. A negative configured `build.jobs` is `E_CONFIG`.
The CLI option itself expects a nonnegative integer.

Other build systems select their own parallelism when executing exported graphs,
for example `ninja -j 8` or `cmake --build ... -j 8`.

## 9.7 Cache-directory interpretation

`build.cache_dir` controls graph caches, not package-cache location. Native
graph caches add `graphs/<root-hash>/`; exported Meson action caches use a
subdirectory of the same graph cache partition.

A leading `~` is expanded with the process's `HOME` value when the graph cache
directory is resolved. This is a small leading-tilde expansion, not general
shell expansion: `$VARIABLE` text and `~otheruser` lookup are not implemented.
Use an absolute path for predictable behavior, especially on Windows.

A relative configured cache directory is resolved against the invoking
process's working directory. Because `-C` does not change that directory, a
relative cache path can select different locations depending on how the CLI is
invoked. An absolute cache path avoids that ambiguity.

Package caches remain under `<cache-home>/rattpack/pkgs`, independently of
`build.cache_dir`. Moving the package cache home requires the platform cache-
home environment setting or an equivalent deployment arrangement.

## 9.8 Captured settings

Graph actions serialize the config values used during construction. Native
execution and exporter action runners restore those values for the action's
standard library. They do not reread `Config.toml` to supply execution-time
`env.get` results.

Consequences:

- A native build that reloads specs can capture a newly edited config.
- A saved/exported graph retains its original action settings until rebuilt or
  re-exported.
- Configuration is part of action recipes; changing settings can invalidate
  actions even when their source files are unchanged.
- Process environment is separate from configuration. Normal sandboxed actions
  use captured backend defaults plus the target's `env:` map; `proc.env` reads
  that map during execution. Standalone and `sandbox: false` execution instead
  read ambient values. See [chapter 25](25-hermetic-builds.md).

The graph-wide cache location used by native commands is chosen from the
configuration at invocation. Frozen action settings still govern its execution
environment and template evaluation.

## 9.9 Isolated settings for a workspace or CI job

On POSIX/macOS, use an explicit XDG home:

```sh
mkdir -p "$PWD/.ci-config/rattpack"
export XDG_CONFIG_HOME="$PWD/.ci-config"
export XDG_CACHE_HOME="$PWD/.ci-cache"
```

Write `Config.toml` under that `rattpack` subdirectory before constructing the
graph. Dot-prefixed directories are excluded from normal spec discovery and
globs. Select actual compiler names and a registry suitable for the job.

This is an environment-based configuration location choice. It is not an
additional Rattpack profile selection mechanism; initialization profiles are
described in the next chapter.
