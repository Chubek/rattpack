# EZDox

EZDox is a flexible, manifest-driven documentation generator for C++ projects.
It transforms structured source comments into HTML, LaTeX, Manpage, ROFF, and
XML output using a clean, extensible pipeline.

## What EZDox Does

- **Scans** C++ source files for Doxygen-style comments.
- **Parses** commands like `@brief`, `@param`, and `@return` from a
  manifest-driven command set.
- **Applies** built-in markups (Markdown, ReStructuredText, Docbook, XWiki).
- **Renders** documentation through built-in targets (HTML, LaTeX, Manpage,
  ROFF, XML).
- **Packages** custom extensions as bundles that can be shared and installed.
- **Validates** configuration against a JSON Schema to catch errors early.
- **Supports** YAML, JSON, and TOML configuration formats.
- **Executes** commands and pipelines defined in your configuration file.

## Quick Example

```cpp
/// @brief Compute the factorial of n.
/// @param n A non-negative integer.
/// @return The factorial of n.
unsigned long factorial(unsigned n);
```

Run EZDox:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs
```

Open `build/docs/html/index.html` to see the generated documentation.

## Manual

The EZDox manual is divided into twelve chapters covering every aspect of the tool:

1. [Introduction to EZDox](manual/01-introduction.md)
2. [Configuration File Reference](manual/02-configuration.md)
3. [CLI Usage Guide](manual/03-cli-usage.md)
4. [Built-in Markups](manual/04-markups.md)
5. [Built-in Targets](manual/05-targets.md)
6. [Bundle System](manual/06-bundles.md)
7. [Doxygen Command Support](manual/07-doxygen-commands.md)
8. [Source Scanning and Discovery](manual/08-source-scanning.md)
9. [Commands and Pipelines](manual/09-pipelines.md)
10. [HTML and LaTeX Templates](manual/10-templates.md)
11. [Installing and Distributing Documentation](manual/11-installation.md)
12. [Troubleshooting and Best Practices](manual/12-troubleshooting.md)

## Project Links

- **Homepage**: https://ezdox.dev
- **Repository**: https://github.com/Chubek/EZDox
- **Issue Tracker**: https://github.com/Chubek/EZDox/issues

## License

EZDox is released under the MIT License. See the repository for full details.
EZDox is released under the MIT License. See the repository for full details.
