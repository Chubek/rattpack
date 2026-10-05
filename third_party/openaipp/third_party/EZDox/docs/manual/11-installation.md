# Chapter 11: Installing and Distributing Documentation

After generating documentation, you often need to install it to a public
location, package it for distribution, or serve it from a web server. EZDox
provides the `install` command and several output formats to make this easy.

## Install Command

The `install` command copies or symlinks generated output to a destination:

```bash
ezdox-cli install -O build/docs -d /var/www/docs --mode copy
```

Supported modes:

| Mode     | Behavior                                      |
|----------|-----------------------------------------------|
| `copy`   | Recursive copy with overwrite                 |
| `symlink`| Create a symlink to the output directory      |
| `rsync`  | Recursive copy (future: delta sync)           |

Use `--update` to skip overwriting existing files:

```bash
ezdox-cli install -O build/docs -d /var/www/docs --mode copy --update
```

## Symlink Mode

Symlink mode is useful for development servers:

```bash
ezdox-cli install -O build/docs -d /var/www/docs --mode symlink
```

This creates `/var/www/docs` as a symlink pointing to `build/docs`. When you
regenerate documentation, the web server automatically serves the new content.

## Packaging for Distribution

You can package documentation as a tarball or ZIP archive:

```bash
cd build/docs
tar czf myproject-docs-1.0.0.tar.gz html latex
```

For Debian packages, place HTML output under `/usr/share/doc/myproject/html`:

```bash
sudo mkdir -p /usr/share/doc/myproject/html
sudo cp -r build/docs/html/* /usr/share/doc/myproject/html/
```

## Serving with a Web Server

The HTML output is static and can be served by any web server. For Nginx:

```nginx
server {
    listen 80;
    server_name docs.example.com;
    root /var/www/docs/html;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
```

For Apache:

```apache
<VirtualHost *:80>
    ServerName docs.example.com
    DocumentRoot /var/www/docs/html
</VirtualHost>
```

## CI/CD Integration

In a GitHub Actions workflow:

```yaml
- name: Generate docs
  run: |
    ezdox-cli generate -C EZDox.yaml -O build/docs
    ezdox-cli install -O build/docs -d public/docs --mode copy
- name: Deploy to GitHub Pages
  uses: peaceiris/actions-gh-pages@v3
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    publish_dir: ./public/docs
```

## Versioned Documentation

For projects with multiple releases, maintain versioned directories:

```
/var/www/docs/
  1.0/
    html/
  1.1/
    html/
  latest -> 1.1/
```

Update the `latest` symlink after each release:

```bash
ezdox-cli install -O build/docs -d /var/www/docs/1.1 --mode copy
ln -sfn /var/www/docs/1.1 /var/www/docs/latest
```

## Best Practices

- Use `copy` mode for production deployments.
- Use `symlink` mode for local development.
- Keep old versions accessible for users on legacy releases.
- Validate HTML with `tidy` before deploying.

## C++ API

The `copy_install` function is available for programmatic use:

```cpp
#include "EzDox.hpp"

// Copy mode (recursive copy with overwrite)
ezdox::copy_install("build/docs", "/var/www/docs", false, "copy");

// Symlink mode
ezdox::copy_install("build/docs", "/var/www/docs", false, "symlink");

// Update mode (skip existing files)
ezdox::copy_install("build/docs", "/var/www/docs", true, "copy");
```

Parameters:

- `output`: Source directory containing generated documentation.
- `dest`: Destination path.
- `update`: If `true`, skip files that already exist in the destination.
- `mode`: `"copy"` (default), `"symlink"`, or `"rsync"`. Throws for
  unsupported modes.

When using `symlink` mode, the destination is created as an absolute symlink
to the source directory. Existing destinations are replaced unless `update` is
`true`.
