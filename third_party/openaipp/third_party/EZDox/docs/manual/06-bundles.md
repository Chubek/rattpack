# Chapter 6: Bundle System

Bundles are the extension mechanism for EZDox. A bundle is a compressed archive
containing markup or target plugins, metadata, and optional dependencies.
Bundles are installed under `$EZDOX_HOME` and discovered automatically at
runtime.

## Bundle Layout

A bundle source directory looks like this:

```
my-bundle/
  markups/
    MyMarkup.cpp
  targets/
    MyTarget.cpp
  meta/
    ezdox-bundle.yaml
```

The `ezdox-bundle.yaml` metadata file contains:

```yaml
name: my-bundle
version: 0.1.0
description: Custom markup and target for MyProject
```

## Building a Bundle

Use the CLI to create an archive from a source directory:

```bash
ezdox-cli bundle build \
  -s extensions/my-bundle \
  -o dist/my-bundle.ezb \
  -n my-bundle \
  -V 0.1.0 \
  -d "Custom markup and target for MyProject"
```

The output file `my-bundle.ezb` is a ZIP archive with a `.ezb` extension.
You can also produce `.zip`, `.tar.gz`, or `.tgz` archives by changing the
output file name.

## Installing a Bundle

Install a bundle into `$EZDOX_HOME`:

```bash
ezdox-cli bundle install -b dist/my-bundle.ezb
```

Use `--force` to replace an existing bundle:

```bash
ezdox-cli bundle install -b dist/my-bundle.ezb --force
```

Bundles are extracted to `${EZDOX_HOME}/bundles/<name>` and registered in
the local metadata store.

## Listing Bundles

```bash
ezdox-cli bundle list --long
```

Output:

```
my-bundle	/home/user/.ezdox/bundles/my-bundle
another-bundle	/home/user/.ezdox/bundles/another-bundle
```

## Inspecting a Bundle

Before installing, you can inspect the contents of a bundle archive:

```bash
ezdox-cli bundle inspect -b dist/my-bundle.ezb --json
```

The `--json` flag emits a JSON array of entry paths.

## Removing a Bundle

```bash
ezdox-cli bundle remove -n my-bundle -y
```

The `-y` flag skips the confirmation prompt.

## Bundle Search Path

EZDox searches for bundles in the directories listed in `$EZDOX_BUNDLE_PATH`.
The default path is:

```
${EZDOX_HOME}/bundles:${EZDOX_HOME}/markups:${EZDOX_HOME}/targets
```

You can override this when running EZDox:

```bash
export EZDOX_BUNDLE_PATH=/opt/ezdox/bundles:$EZDOX_BUNDLE_PATH
ezdox-cli generate -C EZDox.yaml
```

## Best Practices

- Version your bundles with semantic versioning.
- Include a `README.md` in the bundle source directory.
- Test bundles in a temporary `$EZDOX_HOME` before installing globally.
