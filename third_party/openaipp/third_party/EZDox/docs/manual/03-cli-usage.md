# Chapter 3: CLI Usage Guide

The EZDox command-line interface is organized around subcommands. Each
subcommand corresponds to a major workflow: generating docs, managing bundles,
inspecting configs, or scanning sources for Doxygen commands.

## Global Options

These options are accepted before any subcommand:

```bash
ezdox-cli -C EZDox.yaml -H ~/.ezdox --color always --verbose
```

- `-C, --config <path>`: Path to the EZDox config file.
- `-H, --home <path>`: Override `$EZDOX_HOME` (default `~/.ezdox`).
- `--color <auto|always|never>`: Control colored output.
- `-v, --verbose`: Increase verbosity; repeat for more detail.
- `-q, --quiet`: Suppress non-error output.
- `--dry-run`: Plan-only mode; print what would be done without modifying
  the filesystem.
- `-j, --jobs <n|auto>`: Number of parallel jobs for generation.
- `--log-file <path>`: Write log output to a file.

## Subcommands Overview

| Command    | Purpose                                      |
|------------|----------------------------------------------|
| `help`     | Show usage information                       |
| `version`  | Print version and build flags                |
| `paths`    | Print resolved EZDox directories             |
| `config`   | Scaffold, validate, print config             |
| `bundle`   | Build, install, list, remove, inspect bundles|
| `find`     | Scan sources for doc comments and commands   |
| `generate` | Render documentation from config and sources |
| `install`  | Install generated docs to a destination      |
| `run`      | Execute a named command or pipeline          |
| `doctor`   | Diagnose environment and config health       |

## Config Subcommands

### Scaffold

Generate a starter configuration file. Supports YAML, JSON, and TOML output:

```bash
ezdox-cli config scaffold -f yaml -o EZDox.yaml \
  -p "MyProject" -V "1.0.0" -m Markdown -t HTML -S src

# Generate a TOML config instead
ezdox-cli config scaffold -f toml -o EZDox.toml \
  -p "MyProject" -V "1.0.0" -m Markdown -t HTML -S src
```

### Validate

Check a config file for structural errors and schema compliance:

```bash
ezdox-cli config validate -C EZDox.yaml
```

### Print

Print the parsed configuration, optionally filtered by key or converted to a
different format:

```bash
# Print a specific key
ezdox-cli config print -C EZDox.yaml --key project

# Convert to JSON
ezdox-cli config print -C EZDox.yaml --format json

# Convert to TOML
ezdox-cli config print -C EZDox.yaml --format toml
```

## Bundle Subcommands

Bundles let you distribute custom markups and targets. The workflow is:

```bash
ezdox-cli bundle build -s extensions/my-bundle -o dist/my-bundle.ezb \
  -n my-bundle -V 0.1.0 -d "My custom bundle"

ezdox-cli bundle install -b dist/my-bundle.ezb --force

ezdox-cli bundle list --long

ezdox-cli bundle inspect -b dist/my-bundle.ezb --json

ezdox-cli bundle remove -n my-bundle -y
```

## Find Subcommand

The `find` command scans source files for Doxygen-style comments:

```bash
ezdox-cli find -S src -g "**/*.cpp" -c "@param" --summary
```

Use `--json` to emit machine-readable output for integration with CI systems.
Use `--count` to print only the number of matching items.

## Generate Subcommand

The `generate` command is the main documentation renderer:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t HTML -m Markdown --clean
```

Add `--profile` to print the number of doc items discovered after generation.
Use `--template` to specify a custom Inja template directory.

## Install Subcommand

Copy or symlink generated documentation to a destination:

```bash
# Copy (default)
ezdox-cli install -O build/docs -d /var/www/docs --mode copy

# Symlink for local development
ezdox-cli install -O build/docs -d ~/public_html/docs --mode symlink

# Update existing installation
ezdox-cli install -O build/docs -d /var/www/docs --update
```

## Run Subcommand

Execute a named command or pipeline defined in the config:

```bash
ezdox-cli run -C EZDox.yaml -n build --dry-run
ezdox-cli run -C EZDox.yaml -n release -e BRANCH=main -t 30s
```

Passthrough arguments after `--` are forwarded to the command:

```bash
ezdox-cli run -C EZDox.yaml -n build -- --fast --no-cache
```

## Environment Variables

| Variable         | Default       | Purpose                          |
|------------------|---------------|----------------------------------|
| `EZDOX_HOME`     | `~/.ezdox`    | Root for bundles, cache, etc.    |
| `EZDOX_CONFIG`   | `EZDox.yaml`  | Default config file name         |
| `EZDOX_COLOR`    | `auto`        | Color output mode                |
| `EZDOX_JOBS`     | `auto`        | Parallelism for generation       |

## Exit Codes

| Code | Meaning            |
|------|--------------------|
| 0    | Success            |
| 1    | General failure    |
| 2    | Config error       |
| 3    | Invalid arguments  |
| 4    | Not found          |
| 5    | Dependency missing |
