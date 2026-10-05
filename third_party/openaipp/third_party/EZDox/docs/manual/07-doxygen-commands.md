# Chapter 7: Doxygen Command Support

EZDox recognizes Doxygen-style commands embedded in C++ comments. The list of
supported commands is loaded from `manifests/doxygen-commands.yaml` at runtime.
This chapter explains how commands are parsed, how they map to the document
model, and how you can extend the command set.

## Command Syntax

Doxygen commands begin with a backslash or at-sign:

```cpp
/// \brief Brief description
/// \param x Parameter description
/// \return Return description

/** @brief Brief description
 *  @param x Parameter description
 *  @return Return description
 */
```

EZDox normalizes both `\` and `@` prefixes internally, so you can mix them
freely within a project.

## Core Commands

The following commands are always recognized:

| Command   | Purpose                              |
|-----------|--------------------------------------|
| `@brief`  | Short summary of the entity          |
| `@details`| Extended description                 |
| `@param`  | Document a function parameter        |
| `@return` | Document the return value            |
| `@see`    | Cross-reference another entity       |
| `@ref`    | Inline reference to another entity   |
| `@code`   | Start a code block                   |
| `@endcode`| End a code block                     |
| `@pre`    | Precondition                         |
| `@post`   | Postcondition                        |
| `@note`   | Advisory note                        |
| `@warning`| Warning about usage                  |

## Example in Source

```cpp
/**
 * @brief Compute the greatest common divisor.
 * @details Uses Euclid's algorithm. The runtime is O(log min(a,b)).
 * @param a First non-negative integer.
 * @param b Second non-negative integer.
 * @return The GCD of a and b.
 * @pre a >= 0 && b >= 0
 * @see std::gcd (C++17)
 */
int gcd(int a, int b);
```

EZDox extracts:

- `brief`: "Compute the greatest common divisor."
- `details`: "Uses Euclid's algorithm..."
- `params`: `{"a": "First non-negative integer.", "b": "Second non-negative integer."}`
- `returns`: "The GCD of a and b."
- `references`: `["std::gcd"]`
- `commands`: `["@brief", "@details", "@param", "@return", "@pre", "@see"]`

## Command Manifest

The authoritative list of commands lives in `manifests/doxygen-commands.yaml`.
Each entry contains:

- `id`: Unique identifier (e.g., `cmdaddtogroup`).
- `title`: Human-readable title with argument syntax.
- `paragraphs`: Description paragraphs.
- `preformatted`: Example code blocks.

You can add project-specific commands by appending entries to this file or by
creating a custom manifest and referencing it in `EZDox.yaml`.

## Filtering by Command

The `find` command lets you search for specific commands in your codebase:

```bash
ezdox-cli find -S src -c "@pre" --summary
```

This is useful for auditing preconditions or ensuring that every public function
has a `@return` tag.

## Extending Commands

To add a custom command:

1. Edit `manifests/doxygen-commands.yaml` (or create a copy).
2. Add an entry with `id`, `title`, and `text`.
3. Reference the manifest in `EZDox.yaml` under `doxygen_compat.import`.

Custom commands are treated exactly like built-in commands during parsing.
