# Chapter 1: Introduction to EZDox

EZDox is a flexible documentation generator designed for modern C++ projects.
It reads structured comments from your source code and transforms them into
rich documentation in multiple formats. Unlike traditional tools, EZDox is
built around a manifest-driven architecture that keeps behavior explicit and
extensible.

## Why EZDox?

Many documentation generators are monolithic and difficult to extend. EZDox
takes a different approach by separating concerns into small, composable pieces:
markups, targets, bundles, and commands. Each piece is governed by a manifest,
so you always know what the tool will do.

```cpp
// A simple documented function
/// @brief Compute the square of a number
/// @param x The input value
/// @return The squared result
int square(int x) {
    return x * x;
}
```

The comment above contains three Doxygen-style commands. EZDox recognizes
`@brief`, `@param`, and `@return` automatically because they are listed in
`manifests/doxygen-commands.yaml`. You can add custom commands to that manifest
if your project uses additional directives.

## Core Concepts

Before you write your first config file, it helps to understand the vocabulary
used throughout EZDox:

- **Markup**: A lightweight syntax for formatting doc text. Built-in markups
  include Markdown, ReStructuredText, Docbook, and XWiki.
- **Target**: An output format such as HTML, LaTeX, Manpage, ROFF, or XML.
- **Bundle**: A packaged extension containing markup or target plugins.
- **Config**: The `EZDox.yaml` (or `.json`, `.sexp`, `.xml`) file that tells
  EZDox which sources to scan, which markups to apply, and which targets to
  render.

## Quick Start

Create a minimal configuration with the CLI scaffold command:

```bash
ezdox-cli config scaffold -f yaml -o EZDox.yaml \
  -p "MyProject" -V "1.0.0" \
  -m Markdown -t HTML -S src -I include
```

This produces a starter file that you can edit later. After editing, run:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs
```

The output directory will contain an `index.html` file and any auxiliary assets
that the HTML target needs. You can open `build/docs/html/index.html` in a
browser to preview the results.

## Installation

EZDox is distributed as source and builds with CMake. A typical install looks
like this:

```bash
git clone https://github.com/example/ezdox.git
cd ezdox
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
sudo make install
```

After installation the `ezdox-cli` binary is available in your PATH. You can
verify it by running `ezdox-cli version`.

## Next Steps

In the next chapter we will examine the configuration file in detail and
learn how to tune every option to match your project's layout.
