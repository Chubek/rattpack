# Chapter 2: Configuration File Reference

The EZDox configuration file is the heart of every documentation run. It
describes your project, points to source directories, selects markups and
targets, and can even define custom commands and pipelines.

## Supported Formats

EZDox accepts YAML, JSON, and TOML config formats:

| Extension | Parser used              |
|-----------|--------------------------|
| `.yaml`   | YAML via `yaml-cpp`      |
| `.yml`    | YAML via `yaml-cpp`      |
| `.json`   | JSON via `nlohmann-json` |
| `.toml`   | TOML via `tomlplusplus`  |

You do not need to tell EZDox which parser to use; it detects the format
automatically from the file extension.

## Minimal Example

```yaml
project: "MyProject"
version: "1.0.0"
sources:
  - src
includes:
  - include
excludes:
  - build
targets:
  - HTML
markups:
  - Markdown
```

Or the equivalent in TOML:

```toml
project = "MyProject"
version = "1.0.0"
sources = ["src"]
includes = ["include"]
excludes = ["build"]
targets = ["HTML"]
markups = ["Markdown"]
```

Save the file as `EZDox.yaml` in your project root. EZDox will find it
automatically when you run `ezdox-cli generate` without an explicit `-C` flag.

## Field Reference

- `project` (string): Human-readable project name used in titles and headers.
- `version` (string): Version string displayed next to the project name.
- `sources` (list of paths): Directories to scan for documented source files.
  At least one source is required.
- `includes` (list of paths): Additional include directories for context.
- `excludes` (list of paths): Glob patterns or directories to skip during scanning.
- `targets` (list of strings): Output formats to generate. Built-in values:
  `HTML`, `LaTeX`, `Manpage`, `ROFF`, `XML`. At least one target is required.
- `markups` (list of strings): Markup parsers to apply. Built-in values:
  `Markdown`, `ReStructuredText`, `Docbook`, `XWiki`. At least one markup is required.
- `frontpage` (string): Path to a Markdown file used as the documentation
  landing page. If omitted, a default front page is generated.
- `manual` (string): Path to a directory of Markdown chapters that form the
  user manual. Chapters are sorted alphabetically by filename.
- `commands` (map of string to string): Named shell commands that can be
  executed via `ezdox-cli run`.
- `pipelines` (map of string to list of strings): Named pipelines composed of
  commands executed in sequence.
- `environment` (map of string to string): Environment variables set when
  running commands or pipelines.
- `template` (string): Path to a custom template directory for HTML and LaTeX
  output. Uses the Inja templating engine.
- `output` (string): Default output directory. Defaults to `build/docs`.
- `doxygen_compat` (boolean): Enable Doxygen command recognition. Defaults to
  `true`.
- `bundles` (list of strings): Bundles to load before generation.
- `defines` (map of string to string): Preprocessor definitions passed to the
  scanner.
- `strict` (boolean): Treat warnings as errors. Defaults to `false`.
- `jobs` (integer or `"auto"`): Number of parallel jobs. Defaults to `"auto"`.

## Commands and Pipelines

You can define shell commands inside the config:

```yaml
commands:
  build: "ezdox-cli generate -C EZDox.yaml -O build/docs"
  publish: "rsync -avz build/docs/ docs.example.com:/var/www/docs"

pipelines:
  release:
    - build
    - publish
```

Run a command with `ezdox-cli run -C EZDox.yaml -n build`. Run a pipeline with
`ezdox-cli run -C EZDox.yaml -n release`. Commands support environment
injection, working directory overrides, timeouts, and passthrough arguments.

## Environment Variables

The config file can reference environment variables that EZDox injects into
command execution:

```yaml
environment:
  EZDOX_COLOR: "auto"
  EZDOX_JOBS: "4"
```

These values are exported before each command in a pipeline. You can override
them on the CLI with `-e KEY=VALUE` or `--env KEY=VALUE`.

## Validation

EZDox validates your configuration at two levels:

1. **Basic validation** (`validate_config`): Checks that required fields
   (`project`, `sources`, `targets`, `markups`) are non-empty and that
   referenced paths (frontpage, manual directory) exist.

2. **Schema validation** (`validate_config_against_schema`): Validates the
   config against `manifests/ezdox-config.schema.json` using the ValiJSON
   library. Catches type mismatches, missing required fields, and invalid
   values.

Validate a config from the CLI:

```bash
ezdox-cli config validate -C EZDox.yaml
```

If the file is malformed or references unknown targets, the command exits with
code 2 and prints a list of errors.

## Config Scaffold

Generate a starter config with the `config scaffold` command. All options are
optional; omitted values use defaults.

```bash
ezdox-cli config scaffold -f yaml -o EZDox.yaml \
  -p "MyProject" -V "1.0.0" \
  -m Markdown -t HTML -S src -I include
```

| Flag                  | Default        | Description                                           |
|-----------------------|----------------|-------------------------------------------------------|
| `-o`, `--output`      | `EZDox.yaml`   | Output file path.                                     |
| `-p`, `--project`     | `EZDox Project`| Project name.                                         |
| `-V`, `--version`     | `0.1.0`        | Version string.                                       |
| `-f`, `--format`      | `yaml`         | Output format: `yaml`, `json`, or `toml`.             |
| `-m`, `--markups`     | `Markdown`     | Comma-separated list of markup names.                 |
| `-t`, `--targets`     | `HTML`         | Comma-separated list of target names.                 |
| `-S`, `--sources`     | `.`            | Comma-separated list of source directories.           |
| `-I`, `--includes`    | (none)         | Comma-separated list of include directories.          |
| `-E`, `--excludes`    | (none)         | Comma-separated list of exclude patterns.             |
| `--with-pipelines`    | `false`        | Include example pipeline definitions.                 |
| `--with-commands`     | `false`        | Include example command definitions.                  |

## Format Conversion and Dumping

You can convert a config file between formats with the `config print` command:

```bash
# Print config in TOML format
ezdox-cli config print -C EZDox.yaml --format toml
```

Or use the C++ API directly:

```cpp
auto config = ezdox::load_config("EZDox.yaml");
std::string json = ezdox::dump_config(config, "json");
ezdox::write_config(config, "EZDox.toml", "toml");
```

## Tips

- Keep `excludes` strict to avoid scanning generated code or third-party headers.
- Use `includes` only when your source files rely on external headers for
  macro definitions that affect Doxygen parsing.
- Store sensitive values in environment variables rather than the config file.
- Add `config validate` to your CI pipeline to catch errors before they reach
  production.
- Use TOML for configs that need to be machine-generated or edited by tools
  that prefer a simpler syntax.
