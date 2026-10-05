# Chapter 9: Commands and Pipelines

EZDox configs can define shell commands and pipelines. This lets you encode
build, test, and publish workflows directly in your documentation configuration.

## Defining Commands

Commands are simple key-value pairs:

```yaml
commands:
  build: "ezdox-cli generate -C EZDox.yaml -O build/docs"
  test: "ctest --output-on-failure"
  publish: "rsync -avz build/docs/ docs.example.com:/var/www/docs"
```

Each command is executed in a subshell with the current working directory set
to the project root (or overridden with `-w`).

## Defining Pipelines

Pipelines are ordered lists of command names or raw shell strings:

```yaml
pipelines:
  ci:
    - build
    - test
    - publish
  local:
    - build
    - "echo 'Docs built locally'"
```

Run a pipeline with:

```bash
ezdox-cli run -C EZDox.yaml -n ci
```

## Environment Injection

You can inject environment variables from three sources:

1. The `environment` section of `EZDox.yaml`.
2. The `-e` / `--env` CLI options.
3. Inherited variables from the parent shell.

```yaml
environment:
  EZDOX_COLOR: "always"
  DEPLOY_KEY: "${DEPLOY_KEY}"
```

```bash
ezdox-cli run -C EZDox.yaml -n publish -e BRANCH=main
```

## Dry Runs

Use `--dry-run` to preview commands without executing them:

```bash
ezdox-cli run -C EZDox.yaml -n ci --dry-run
```

Output:

```
cd /home/user/project && EZDOX_COLOR='always' ezdox-cli generate -C EZDox.yaml -O build/docs
cd /home/user/project && EZDOX_COLOR='always' ctest --output-on-failure
cd /home/user/project && EZDOX_COLOR='always' DEPLOY_KEY='secret' rsync -avz build/docs/ docs.example.com:/var/www/docs
```

## Timeouts

Prevent hanging commands with the `--timeout` option:

```bash
ezdox-cli run -C EZDox.yaml -n test --timeout 300
```

If a command exceeds the timeout, EZDox aborts the pipeline and returns a
non-zero exit code.

## Passthrough Arguments

Arguments after `--` are forwarded to the command:

```bash
ezdox-cli run -C EZDox.yaml -n test -- --verbose -R markup
```

The command becomes:

```bash
ctest --output-on-failure --verbose -R markup
```

## Best Practices

- Keep commands idempotent so they can be rerun safely.
- Use pipelines to group related steps (build, test, deploy).
- Store secrets in environment variables, not in the config file.
- Use `--dry-run` in CI to validate pipeline definitions before execution.
