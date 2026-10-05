# Chapter 1: Introduction {#chapter1}

## What is Ekipp?

Ekipp is a modern C++17 text preprocessing library that provides powerful macro expansion and directive-based text transformation capabilities. Unlike traditional C preprocessors, Ekipp is designed to be embedded in applications and offers a clean, extensible API for custom text processing needs.

## Design Philosophy

Ekipp follows these core principles:

1. **Simplicity** - Easy to integrate and use, with sensible defaults
2. **Extensibility** - Custom directives are first-class citizens
3. **Safety** - Strong error handling with detailed source locations
4. **Performance** - Zero-cost abstractions where possible
5. **Flexibility** - Configurable syntax and behavior

## Key Concepts

### Directives

Directives are the primary mechanism for text transformation in Ekipp. A directive is invoked using a prefix character (default `@`) followed by a name and optional arguments:

```
@directive_name(arg1, arg2, ...)@
```

### Macros

Macros provide text substitution capabilities similar to C preprocessor macros:

- **Object-like macros**: Simple text replacement
- **Function-like macros**: Parameterized text expansion

### Context

Every directive execution receives a Context object containing:
- Current source location
- Symbol table (macros)
- Configuration
- Custom properties

## Installation

Ekipp is a header-only library. To use it:

1. Copy `include/ekipp.hpp` and `include/directive_bank.hpp` to your project
2. Add the include directory to your compiler's include path
3. Include the headers in your code

```cpp
#include <ekipp/ekipp.hpp>
#include <ekipp/directive_bank.hpp>
```

### Requirements

- C++17 compatible compiler (GCC 7+, Clang 5+, MSVC 2017+)
- Standard library with filesystem support

### Building Examples

```bash
make examples
make test
```

## Architecture Overview

```
┌─────────────────┐
│  Preprocessor   │  Main entry point
└────────┬────────┘
         │
    ┌────┴────┬──────────┬──────────┐
    │         │          │          │
┌───▼───┐ ┌──▼──────┐ ┌─▼────────┐ ┌▼──────────┐
│Config │ │Registry │ │SymbolTbl │ │  Context  │
└───────┘ └─────────┘ └──────────┘ └───────────┘
```

### Component Responsibilities

- **Preprocessor**: Orchestrates parsing and directive execution
- **Configuration**: Stores limits, parse style, and parameters
- **DirectiveRegistry**: Manages available directives
- **SymbolTable**: Handles macro definitions and expansion
- **Context**: Provides runtime state to directives

## Hello World Example

```cpp
#include <ekipp/ekipp.hpp>
#include <iostream>

int main() {
    ekipp::Preprocessor pp;
    
    // Register a simple directive
    auto hello = ekipp::Directive::fluent()
        << ekipp::Directive::Name("hello")
        << ekipp::Directive::NumParams(1)
        << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
            return "Hello, " + args.raw(0) + "!";
        });
    
    pp.registry().registerDirective(hello);
    
    std::string input = "@hello(World)@";
    std::cout << pp.process(input) << std::endl;
    // Output: Hello, World!
}
```

## Next Steps

Continue to [Chapter 2: Basic Usage](@ref chapter2) to learn how to use Ekipp in your projects.
