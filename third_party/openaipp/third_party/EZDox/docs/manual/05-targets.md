# Chapter 5: Built-in Targets

Targets consume the document model produced by EZDox and emit final artifacts.
EZDox provides five built-in targets: HTML, LaTeX, Manpage, ROFF, and XML.

## HTML Target

The HTML target is the most commonly used. It produces a directory of files
including `index.html`, CSS assets, and JavaScript libraries. The HTML target
uses the Inja template engine when `EZDOX_USE_INJA` is enabled at compile
time.

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t HTML
```

The output directory structure looks like this:

```
build/docs/html/
  index.html
  csslib/
    bootstrap.min.css
    highlight.min.css
  jslib/
    highlight.min.js
    mathjax.js
```

You can customize the appearance by providing your own template directory:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t HTML --template my-templates/
```

## LaTeX Target

The LaTeX target emits `.tex` files and a custom `ezdox.cls` class file. You
can compile the output with `pdflatex` or `xelatex` to produce a PDF manual.

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t LaTeX
cd build/docs/latex
pdflatex manual.tex
```

LaTeX output uses `lstlisting` environments for code blocks and `hyperref` for
cross-references. The `ezdox.cls` class defines colors and geometry suitable
for technical documentation.

## Manpage Target

The Manpage target generates traditional Unix manual pages in ROFF format.
Each documented function becomes a separate `.1` file (or `.3` for library
functions).

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t Manpage
man build/docs/man/ezdox.1
```

Manpages are ideal for CLI tools and library APIs that users expect to access
via `man`.

## ROFF Target

The ROFF target is a lower-level variant of the Manpage target. It emits
general-purpose ROFF documents rather than strict manpage sections. Use this
when you need fine-grained control over headers, footers, and page layout.

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t ROFF
```

## XML Target

The XML target produces a structured XML representation of the document model.
This is useful for downstream processing with XSLT or for importing into
content-management systems.

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t XML
```

The XML schema includes elements for `project`, `version`, `item`, `param`,
`return`, and `reference`.

## Target Selection

In `EZDox.yaml`:

```yaml
targets:
  - HTML
  - LaTeX
```

EZDox runs each target independently and writes output to a subdirectory named
after the target in lowercase (e.g., `html/`, `latex/`, `man/`, `roff/`,
`xml/`).

## Target API

EZDox exposes a C++ API for target rendering:

```cpp
#include "EzDox-Target.hpp"

ezdox::DocumentModel model{config, items};

// Render individual targets
ezdox::target_html(model, "output/html");
ezdox::target_latex(model, "output/latex");
ezdox::target_manpage(model, "output/man");
ezdox::target_roff(model, "output/roff");
ezdox::target_xml(model, "output/xml");

// Render with custom templates
ezdox::target_html(model, "output/html", "my-templates/");
ezdox::target_latex(model, "output/latex", "my-templates/");

// Resolve by name (falls back to plain text if unrecognized)
ezdox::resolve_target("HTML", model, "output/html");
```

The `resolve_target` function accepts case-insensitive names. Unrecognized
target names produce a plain `.txt` file using the default markup. The public
`render_target` and `generate` functions are wrappers around `resolve_target`.

## Custom Targets

Custom targets are implemented by following the interface pattern in
`include/EzDox-Target.hpp`. Like custom markups, they are distributed as
bundles and installed under `$EZDOX_HOME/targets`.
