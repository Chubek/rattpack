# Ekipp - Modern C++17 Text Preprocessor Library

## Welcome to Ekipp

Ekipp is a powerful, extensible text preprocessing library for C++17 that provides a flexible macro system and directive-based text transformation capabilities. It's designed to be embedded in applications that need sophisticated text processing, code generation, or template expansion.

## Key Features

- **Header-only library** - Easy integration, just include the headers
- **Modern C++17** - Uses latest language features for clean, efficient code
- **Extensible directive system** - Define custom directives with simple lambdas
- **Macro support** - Both object-like and function-like macros
- **Configurable syntax** - Customize prefix, brackets, and separators
- **Source location tracking** - Detailed error reporting with file/line/column
- **Zero dependencies** - Only requires C++17 standard library
- **Embedding hooks** - Integrate with Lua, JavaScript, or other languages
- **Binary serialization** - Save and load directive registries

## Quick Start

```cpp
#include <ekipp/ekipp.hpp>
#include <ekipp/directive_bank.hpp>

int main() {
    ekipp::Preprocessor pp;
    ekipp::directive_bank::register_all(pp.registry());
    
    std::string input = "@define(NAME, World)@Hello, @NAME@!";
    std::string output = pp.process(input);
    // Output: "Hello, World!"
}
```

## Documentation Structure

This documentation is organized into five chapters:

1. **[Introduction](@ref chapter1)** - Overview, installation, and basic concepts
2. **[Basic Usage](@ref chapter2)** - Getting started with preprocessing
3. **[Directives](@ref chapter3)** - Built-in directives and the directive bank
4. **[Advanced Features](@ref chapter4)** - Macros, embedding, and customization
5. **[Extending Ekipp](@ref chapter5)** - Creating custom directives and integrations

## Architecture

Ekipp is built around several core components:

- **Preprocessor** - Main processing engine
- **DirectiveRegistry** - Manages available directives
- **SymbolTable** - Stores and expands macros
- **Configuration** - Controls parsing and behavior
- **Context** - Runtime state passed to directives

## Use Cases

- **Code generation** - Generate repetitive code from templates
- **Documentation processing** - Preprocess markdown or other docs
- **Configuration files** - Add macro expansion to config formats
- **Build systems** - Custom preprocessing in build pipelines
- **Template engines** - Create domain-specific template languages

## License

Ekipp is released under the MIT License. See the LICENSE file for details.

## Getting Help

- Read the [User Manual](manual/chapter1_introduction.md)
- Check the [examples](examples.html) directory
- Browse the [API Reference](annotated.html)
- Report issues on GitHub

---

**Version:** 2.0.0  
**C++ Standard:** C++17 or later  
**Maintained by:** The Ekipp Contributors
