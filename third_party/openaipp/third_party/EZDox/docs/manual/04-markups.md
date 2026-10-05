# Chapter 4: Built-in Markups

Markups transform raw doc comments into structured text. EZDox ships with
four built-in markups: Markdown, ReStructuredText, Docbook, and XWiki. You can
also install custom markups via bundles.

## Markdown

Markdown is the default markup because it is readable in source form and
renders well to HTML. EZDox applies Markdown to `@brief` and `@details` text
before passing it to the target renderer.

```cpp
/// @brief Converts a string to uppercase.
/// @details This function allocates a new `std::string` and copies
///          characters while applying `std::toupper`.
/// @param s Input string.
/// @return Uppercased copy.
std::string to_upper(const std::string& s);
```

The Markdown markup will wrap the brief in a paragraph and the details in a
code block if indented. Parameters are rendered as a bullet list with a
`Parameters` heading. Cross-references use `@ref` links rendered as
`[symbol](#anchor)`.

## ReStructuredText

ReStructuredText (RST) is popular in the Python ecosystem and supported by
Sphinx. EZDox generates RST sections with `.. cpp:function::` directives.

```cpp
/// @brief Compute factorial
/// @param n Non-negative integer
/// @return n!
unsigned long factorial(unsigned n);
```

RST output looks like:

```rst
.. cpp:function:: unsigned long factorial(unsigned n)

   Compute factorial

   :param n: Non-negative integer
   :return: n!
```

## Docbook

Docbook is an XML-based semantic markup language. EZDox emits `<article>`,
`<section>`, and `<para>` elements so that downstream Docbook pipelines can
produce PDF or HTMLHelp.

```cpp
/// @brief Initialize the logging subsystem.
/// @param level One of DEBUG, INFO, WARN, ERROR.
void init_logging(int level);
```

Docbook output includes `<parameter>` tags for each `@param` and a
`<returnvalue>` tag for `@return`. References are rendered as `<xref>` links.

## XWiki

XWiki syntax is used by the XWiki collaborative platform. EZDox generates
headings with `= Title =`, tables for parameters, and monospaced blocks for
code samples.

```cpp
/// @brief Parse a configuration file.
/// @param path Absolute path to the file.
/// @return Parsed configuration object.
Config parse_config(const std::string& path);
```

XWiki output:

```xwiki
= parse_config =

| Parameter | Description |
|-----------|-------------|
| path      | Absolute path to the file. |

Returns: Parsed configuration object.
```

## Selecting Markups

In `EZDox.yaml`:

```yaml
markups:
  - Markdown
  - ReStructuredText
```

When multiple markups are listed, EZDox generates one intermediate file per
markup for each target that supports it. Not all targets consume all markups;
HTML prefers Markdown, while LaTeX can accept either Markdown or Docbook.

## Markup API

EZDox exposes a C++ API for markup generation:

```cpp
#include "EzDox-Markup.hpp"

ezdox::DocumentModel model{config, items};
std::string md  = ezdox::markup_markdown(model);
std::string rst = ezdox::markup_restructuredtext(model);
std::string db  = ezdox::markup_docbook(model);
std::string xw  = ezdox::markup_xwiki(model);

// Resolve by name (falls back to Markdown if unrecognized)
std::string result = ezdox::resolve_markup("Docbook", model);
```

The `resolve_markup` function accepts case-insensitive names and falls back to
Markdown for unrecognized markup names. The public `apply_markup` function is
a thin wrapper around `resolve_markup`.

## Custom Markups

You can write a custom markup by implementing a function with the signature
`std::string(const DocumentModel&)` and registering it. After compiling your
markup into a shared library, package it as a bundle and install it with
`ezdox-cli bundle install`.
