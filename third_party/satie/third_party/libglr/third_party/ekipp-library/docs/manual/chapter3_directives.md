# Chapter 3: Directives {#chapter3}

## Understanding Directives

Directives are the primary extension mechanism in Ekipp. Each directive is a named operation that takes arguments and produces output.

## Directive Syntax

Basic syntax:
```
@directive_name(arg1, arg2, ...)@
```

The syntax is configurable:
- Prefix: `@` (default), can be changed to `#`, `$`, etc.
- Brackets: `()` (default), can be changed to `[]`, `{}`, etc.
- Separator: `,` (default)

## Built-in Directives

### include

Include and process an external file.

**Syntax:** `@include(path)@`

**Example:**
```
@include("header.txt")@
Main content here.
@include("footer.txt")@
```

**Features:**
- Searches relative to current file
- Searches include directories
- Recursively processes included content
- Prevents infinite recursion

### define

Define macros for text substitution.

**Object-like macro:**
```
@define(PI, 3.14159)@
Circle area: @PI@ * r^2
```

**Function-like macro:**
```
@define(MAX(a,b), ((a) > (b) ? (a) : (b)))@
Maximum: @MAX(10, 20)@
```

**Variadic macro:**
```
@define(LOG(fmt, ...), printf(fmt, __VA_ARGS__))@
@LOG("Value: %d", 42)@
```

### date

Insert current date and time.

**Syntax:** `@date([format])@`

**Examples:**
```
@date()@                    // 2025-01-15 14:30:00
@date(%Y-%m-%d)@           // 2025-01-15
@date(%H:%M:%S)@           // 14:30:00
@date(%A, %B %d, %Y)@      // Wednesday, January 15, 2025
```

**Format specifiers:** Uses standard `strftime` format codes.

### exec

Execute a shell command and insert its output.

**Syntax:** `@exec(command)@`

**Examples:**
```
Git commit: @exec(git rev-parse --short HEAD)@
Current user: @exec(whoami)@
File count: @exec(ls -1 | wc -l)@
```

**Security note:** Be careful with untrusted input!

### eval

Evaluate numeric expressions.

**Syntax:** `@eval(expression)@`

**Examples:**
```
@eval(2 + 2)@              // 4
@eval(10 * 5)@             // 50
@eval(100 / 4)@            // 25
```

**Note:** Current implementation supports simple expressions. Complex expressions with parentheses and operator precedence are planned.

### env

Get environment variable values.

**Syntax:** `@env(variable, [default])@`

**Examples:**
```
Home: @env(HOME)@
User: @env(USER, unknown)@
Path: @env(PATH)@
```

If the variable doesn't exist and no default is provided, returns empty string.

## Directive Properties

### IO Type

Directives can be read-only, write-only, or read-write:

- **Read (`r`)**: Produces output, doesn't modify state
- **Write (`w`)**: Modifies state (e.g., defines macros), no output
- **Read-Write (`rw`)**: Both produces output and modifies state

### Arity

Directives can specify:
- **Exact arity**: `NumParams(2)` - exactly 2 arguments
- **Minimum**: `MinParams(1)` - at least 1 argument
- **Maximum**: `MaxParams(3)` - at most 3 arguments
- **Range**: `MinParams(1) << MaxParams(3)` - 1 to 3 arguments

### Categories

Directives can be categorized for organization:
- `file` - File operations
- `macro` - Macro definitions
- `system` - System interaction
- `math` - Mathematical operations
- `utility` - General utilities

## Directive Metadata

Directives can store arbitrary metadata:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("custom")
    << ekipp::Directive::Metadata("version", ekipp::Value("1.0"))
    << ekipp::Directive::Metadata("author", ekipp::Value("John Doe"));
```

## Argument Specifications

Directives can specify expected argument types:

```cpp
using namespace ekipp;

auto dir = Directive::fluent()
    << Directive::Name("example")
    << Directive::Arg(directives::arg("filename", "string", false))
    << Directive::Arg(directives::arg("count", "integer", true));
```

Arguments can be:
- Required or optional
- Typed (string, integer, boolean, etc.)
- Documented with descriptions

## Directive Aliases

Directives can have multiple names:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("include")
    << ekipp::Directive::Alias("import")
    << ekipp::Directive::Alias("require");

// All of these work:
// @include("file.txt")@
// @import("file.txt")@
// @require("file.txt")@
```

## Validation

Directives can include custom validation:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("range")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Validator([](const ekipp::Arguments& args) {
        int value = args.get<int>(0);
        if (value < 0 || value > 100) {
            throw ekipp::DirectiveError("value must be between 0 and 100");
        }
    });
```

## Result Filtering

Post-process directive output:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("upper")
    << ekipp::Directive::ResultFilter([](std::string result) {
        std::transform(result.begin(), result.end(), result.begin(), ::toupper);
        return result;
    });
```

## Nested Directives

By default, directive arguments are not processed. Enable nested processing:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("nested")
    << ekipp::Directive::AllowNested(true);

// Now this works:
// @nested(@date()@)@
```

## Next Steps

Continue to [Chapter 4: Advanced Features](@ref chapter4) to learn about advanced preprocessing techniques.
