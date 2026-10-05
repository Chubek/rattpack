# Chapter 8: Source Scanning and Discovery

EZDox discovers documented entities by scanning C++ source files for comment
blocks that contain Doxygen commands. This chapter explains the scanning
algorithm, the file filters, and how to tune performance for large projects.

## Scanning Algorithm

The scanner operates in three phases:

1. **File enumeration**: Walk `sources` directories, respecting `excludes`.
2. **Comment extraction**: Identify `///`, `/**`, and `/*!` comment blocks.
3. **Command parsing**: Split comment text into lines, detect commands, and
   populate a `DocItem` structure.

```cpp
struct DocItem {
  std::filesystem::path file;
  std::size_t line = 0;
  std::string kind;
  std::string symbol;
  std::string brief;
  std::string details;
  std::map<std::string, std::string> params;
  std::string returns;
  std::vector<std::string> references;
};
```

## File Filters

By default, EZDox scans `.cpp`, `.hpp`, `.h`, `.cc`, and `.cxx` files. You can
narrow the search with glob patterns:

```bash
ezdox-cli find -S src -g "**/*.cpp" -g "**/*.hpp"
```

In `EZDox.yaml`:

```yaml
sources:
  - src
excludes:
  - build
  - third_party
```

Exclusions are applied before comment extraction, so large `build` directories
do not slow down the scan.

## Comment Styles

EZDox recognizes three comment styles:

```cpp
/// Single-line triple-slash comments
/// @brief Brief text

/**
 * Block comments with asterisks
 * @param x Description
 */

/*!
 * Block comments with exclamation marks
 * @return Description
 */
```

Trailing comments are also supported:

```cpp
int value; /**< @brief A documented field */
```

## Symbol Detection

After extracting a comment block, EZDox looks for the next declaration or
definition. It uses a simple heuristic: the first line after the comment that
looks like a function signature, class declaration, or variable definition is
assumed to be the associated symbol.

```cpp
/// @brief A class representing a point.
class Point {
public:
    /// @brief Construct from coordinates.
    /// @param x X coordinate.
    /// @param y Y coordinate.
    Point(double x, double y);
};
```

The scanner identifies `Point` as a class and `Point(double x, double y)` as a
constructor.

## Performance Tips

- Use `excludes` aggressively to skip generated code and vendor directories.
- Run `ezdox-cli find --summary` before generation to estimate scan time.
- For CI, cache the document model between builds if sources have not changed.

## Integration with IDEs

The JSON output from `find` is designed for IDE integration:

```bash
ezdox-cli find -S src --json > doc-index.json
```

IDEs can consume `doc-index.json` to provide hover tooltips and navigation.
