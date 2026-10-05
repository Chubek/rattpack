# Chapter 2: Basic Usage {#chapter2}

## Creating a Preprocessor

The `Preprocessor` class is the main entry point for text processing:

```cpp
#include <ekipp/ekipp.hpp>

// Default configuration
ekipp::Preprocessor pp;

// Custom configuration
ekipp::Configuration config;
config.limits.max_input_size = 1024 * 1024;  // 1MB
config.parse.directive_prefix = '#';          // Use # instead of @
ekipp::Preprocessor pp_custom(config);
```

## Processing Text

The `process()` method transforms input text:

```cpp
std::string input = "@date()@";
std::string output = pp.process(input);
```

You can optionally provide a source name for better error messages:

```cpp
std::string output = pp.process(input, "myfile.txt");
```

## Using the Directive Bank

The directive bank provides commonly-used directives:

```cpp
#include <ekipp/directive_bank.hpp>

ekipp::Preprocessor pp;
ekipp::directive_bank::register_all(pp.registry());

// Now you can use: include, define, date, exec, eval, env
```

### Available Directives

- **include(path)** - Include and process external file
- **define(name, value)** - Define object-like macro
- **define(name(params), body)** - Define function-like macro
- **date([format])** - Insert current date/time
- **exec(command)** - Execute shell command and insert output
- **eval(expression)** - Evaluate numeric expression
- **env(var, [default])** - Get environment variable

## Configuration Options

### Limits

```cpp
config.limits.max_input_size = 16 * 1024 * 1024;  // 16MB
config.limits.max_output_size = 64 * 1024 * 1024; // 64MB
config.limits.max_expansion_depth = 128;
config.limits.max_arguments = 256;
```

### Parse Style

```cpp
config.parse.directive_prefix = '@';
config.parse.default_left_bracket = '(';
config.parse.default_right_bracket = ')';
config.parse.argument_separator = ',';
config.parse.allow_whitespace_after_name = false;
config.parse.allow_bare_directives = false;
```

### Include Directories

```cpp
config.params.include_dirs.push_back("./templates");
config.params.include_dirs.push_back("/usr/share/myapp/includes");
```

## Working with Macros

### Object-like Macros

```cpp
std::string input = R"(
@define(VERSION, 1.0.0)@
Version: @VERSION@
)";

std::string output = pp.process(input);
// Output: Version: 1.0.0
```

### Function-like Macros

```cpp
std::string input = R"(
@define(SQUARE(x), (x) * (x))@
Result: @SQUARE(5)@
)";

std::string output = pp.process(input);
// Output: Result: (5) * (5)
```

### Variadic Macros

```cpp
std::string input = R"(
@define(LOG(fmt, ...), printf(fmt, __VA_ARGS__))@
@LOG("Value: %d", 42)@
)";
```

## Error Handling

Ekipp uses exceptions for error reporting:

```cpp
try {
    std::string output = pp.process(input);
} catch (const ekipp::ParseError& e) {
    std::cerr << "Parse error: " << e.what() << std::endl;
} catch (const ekipp::DirectiveError& e) {
    std::cerr << "Directive error: " << e.what() << std::endl;
} catch (const ekipp::MacroError& e) {
    std::cerr << "Macro error: " << e.what() << std::endl;
}
```

## Source Location Tracking

Errors include source location information:

```cpp
ekipp::SourceLocation loc;
loc.source_name = "input.txt";
loc.line = 1;
loc.column = 1;

// Errors will reference this location
```

## Complete Example

```cpp
#include <ekipp/ekipp.hpp>
#include <ekipp/directive_bank.hpp>
#include <iostream>
#include <fstream>

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <input_file>\n";
        return 1;
    }

    try {
        // Read input
        std::ifstream file(argv[1]);
        std::string input((std::istreambuf_iterator<char>(file)),
                          std::istreambuf_iterator<char>());

        // Configure preprocessor
        ekipp::Configuration config;
        config.params.include_dirs.push_back(".");
        
        ekipp::Preprocessor pp(config);
        ekipp::directive_bank::register_all(pp.registry());

        // Process
        std::string output = pp.process(input, argv[1]);
        std::cout << output;

        return 0;

    } catch (const ekipp::Error& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
}
```

## Next Steps

Continue to [Chapter 3: Directives](@ref chapter3) to learn about the built-in directives in detail.
