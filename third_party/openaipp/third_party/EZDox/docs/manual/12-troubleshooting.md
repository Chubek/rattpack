# Chapter 12: Troubleshooting and Best Practices

This final chapter collects common issues, diagnostic techniques, and
recommendations for running EZDox in production environments.

## Common Issues

### Missing Config File

If EZDox cannot find a config file, it falls back to a default configuration
with `sources: ["."]`. This often leads to scanning the entire project root
including `build/` and `third_party/`.

**Fix**: Create `EZDox.yaml` in the project root or pass `-C` explicitly:

```bash
ezdox-cli generate -C /path/to/EZDox.yaml
```

### Empty Output

If `generate` produces an empty `index.html`, the scanner likely found no
doc items.

**Fix**: Run `find` to verify that comments are recognized:

```bash
ezdox-cli find -S src --summary
```

Ensure your comments use `///`, `/**`, or `/*!` and contain at least one
Doxygen command.

### Template Errors

If `inja` throws a parse error, check the template syntax:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t HTML --template my-templates/
```

Common mistakes:

- Missing `{% endfor %}` after a `{% for %}` loop.
- Using `{{ item.param }}` instead of `{{ item.params }}`.
- Unescaped curly braces in LaTeX templates.

### Config Validation Failures

If `config validate` reports schema errors, check the config against
`manifests/ezdox-config.schema.json`:

```bash
ezdox-cli config validate -C EZDox.yaml
```

Common schema violations:

- Missing required fields (`project`, `sources`, `targets`, `markups`).
- Wrong types (e.g., `sources` as a string instead of a list).
- Empty arrays for fields that require at least one element.

Use `config print --format json` to see how EZDox parses your config:

```bash
ezdox-cli config print -C EZDox.yaml --format json
```

### Bundle Install Fails

If `bundle install` reports "bundle already installed", use `--force`:

```bash
ezdox-cli bundle install -b dist/my-bundle.ezb --force
```

## Diagnostic Commands

### Doctor

The `doctor` command checks the environment:

```bash
ezdox-cli doctor
```

Output includes:

- Resolved `$EZDOX_HOME`
- Default config path
- Number of registered CLI commands
- Directory existence checks

Use `--fix` to create missing directories:

```bash
ezdox-cli doctor --fix
```

### Paths

Print all resolved paths:

```bash
ezdox-cli paths --all
```

### Verbose Mode

Add `-v` or `-vv` to any command for detailed logging:

```bash
ezdox-cli generate -C EZDox.yaml -v
```

## Performance

For large projects (>100k lines):

- Use `excludes` to skip generated and vendor code.
- Run `find --summary` before generation to estimate cost.
- Use `--jobs` to enable parallel scanning (future feature).
- Cache the document model between builds if sources are unchanged.

## Security

- Never commit secrets to `EZDox.yaml`. Use environment variables.
- Validate bundle archives before installing from untrusted sources.
- Run `doctor` in CI to catch environment drift early.

## Getting Help

- Read the manifest files in `manifests/` for authoritative behavior specifications.
- Run `ezdox-cli help <command>` for usage information.
- Check the project homepage at https://ezdox.dev for updates.

## Best Practices Summary

1. Keep `EZDox.yaml` in version control.
2. Use semantic versioning for bundles.
3. Validate configs in CI with `config validate`.
4. Test templates on small projects first.
5. Use `symlink` mode for local dev, `copy` mode for production.
6. Document every public function with at least `@brief`.
7. Run `doctor --fix` after installing EZDox for the first time.
8. Exclude `build/`, `third_party/`, and `.git/` from scanning.
9. Use pipelines to automate build-test-deploy workflows.
10. Keep documentation in sync with code releases.
