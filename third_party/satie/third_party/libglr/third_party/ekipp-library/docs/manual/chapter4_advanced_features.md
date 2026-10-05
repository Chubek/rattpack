# Chapter 4: Advanced Features {#chapter4}

## Advanced Macro Techniques

### Macro Guards

Prevent multiple definitions:

```cpp
pp.symbols().define_object("HEADER_GUARD", "1");

if (!pp.symbols().find("HEADER_GUARD")) {
    // Define macros
}
```

### Conditional Macros

Use macros to control text generation:

```
@define(DEBUG, 1)@
@define(LOG(msg), @DEBUG@ ? printf("DEBUG: %s\n", msg) : (void)0)@
```

### Macro Composition

Macros can invoke other macros:

```
@define(INDENT, "    ")@
@define(INDENTED(text), @INDENT@@text@)@
@INDENTED(Hello World)@
```

### Disabling Macros

Temporarily disable macro expansion:

```cpp
auto* macro = pp.symbols().find("MY_MACRO");
if (macro && std::holds_alternative<ekipp::SymbolTable::ObjectMacro>(*macro)) {
    auto& om = std::get<ekipp::SymbolTable::ObjectMacro>(*macro);
    om.enabled = false;
}
```

## Context Properties

Pass custom data to directives:

```cpp
ekipp::Context ctx;
ctx.set("project_name", ekipp::Value("MyProject"));
ctx.set("version", ekipp::Value("1.0.0"));

// In directive:
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("project_info")
    << ekipp::Directive::Semantics([](ekipp::Arguments&, ekipp::Context& ctx) {
        std::string name = ctx.get("project_name").to_string();
        std::string ver = ctx.get("version").to_string();
        return name + " v" + ver;
    });
```

## Custom Syntax

### Changing the Prefix

Use different prefix characters:

```cpp
ekipp::Configuration config;
config.parse.directive_prefix = '#';  // Use # instead of @

// Now use: #include("file.txt")#
```

### Custom Brackets

Use different bracket styles:

```cpp
config.parse.default_left_bracket = '[';
config.parse.default_right_bracket = ']';

// Now use: @include["file.txt"]@
```

### Per-Directive Syntax

Each directive can override the default syntax:

```cpp
auto dir = ekipp::Directive::fluent()
    << ekipp::Directive::Name("special")
    << ekipp::Directive::Prefix('#')
    << ekipp::Directive::LeftBracket('{')
    << ekipp::Directive::RightBracket('}')
    << ekipp::Directive::Separator(';');

// Use: #special{arg1;arg2}#
```

## Opaque I/O Sources

Ekipp supports reading from and writing to abstract sources beyond strings:

```cpp
// Custom input source
class CustomSource {
public:
    virtual char read() = 0;
    virtual bool eof() const = 0;
};

// Custom output sink
class CustomSink {
public:
    virtual void write(const std::string& data) = 0;
};
```

This enables:
- Streaming large files without loading into memory
- Network-based preprocessing
- Database-backed templates
- Encrypted content processing

## Stack-Based Control Flow

Ekipp provides a stack for implementing control flow directives:

```cpp
// Stack for foreach loops, conditionals, etc.
std::vector<ekipp::Value> stack;

auto foreach_start = ekipp::Directive::fluent()
    << ekipp::Directive::Name("foreach")
    << ekipp::Directive::Semantics([&stack](ekipp::Arguments& args, ekipp::Context&) {
        // Push loop state onto stack
        stack.push_back(ekipp::Value(args.raw(0)));
        return std::string();
    });
```

## List Arguments

Directives can accept list-valued arguments:

```cpp
auto sum = ekipp::Directive::fluent()
    << ekipp::Directive::Name("sum")
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
        double total = 0.0;
        for (size_t i = 0; i < args.size(); ++i) {
            total += args.get<double>(i);
        }
        return std::to_string(total);
    });

// Usage: @sum(1, 2, 3, 4, 5)@ => 15
```

## Embedding Hooks

Integrate scripting languages into Ekipp:

### Lua Integration

```cpp
#include <lua.hpp>

auto lua_eval = ekipp::Directive::fluent()
    << ekipp::Directive::Name("lua")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context& ctx) {
        lua_State* L = static_cast<lua_State*>(
            ctx.properties["lua_state"].get<void*>()
        );
        
        luaL_dostring(L, args.raw(0).c_str());
        
        const char* result = lua_tostring(L, -1);
        return std::string(result ? result : "");
    });
```

### JavaScript (QuickJS) Integration

```cpp
#include <quickjs.h>

auto js_eval = ekipp::Directive::fluent()
    << ekipp::Directive::Name("js")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context& ctx) {
        JSRuntime* rt = static_cast<JSRuntime*>(
            ctx.properties["js_runtime"].get<void*>()
        );
        JSContext* js_ctx = JS_NewContext(rt);
        
        JSValue result = JS_Eval(js_ctx, args.raw(0).c_str(), 
                                 args.raw(0).length(), "<eval>", 0);
        
        const char* str = JS_ToCString(js_ctx, result);
        std::string output(str ? str : "");
        
        JS_FreeCString(js_ctx, str);
        JS_FreeValue(js_ctx, result);
        JS_FreeContext(js_ctx);
        
        return output;
    });
```

## Binary Serialization

Save and load directive registries:

```cpp
// Save registry
ekipp::DirectiveSerializer serializer;
std::string binary_data = serializer.serialize(pp.registry());

std::ofstream out("directives.bin", std::ios::binary);
out.write(binary_data.data(), binary_data.size());

// Load registry
std::ifstream in("directives.bin", std::ios::binary);
std::string loaded_data((std::istreambuf_iterator<char>(in)),
                        std::istreambuf_iterator<char>());

ekipp::DirectiveRegistry new_registry;
serializer.deserialize(loaded_data, new_registry);
```

## Performance Optimization

### Precompile Directives

Register directives once and reuse:

```cpp
static ekipp::DirectiveRegistry global_registry;
static bool initialized = false;

if (!initialized) {
    ekipp::directive_bank::register_all(global_registry);
    // Register custom directives
    initialized = true;
}

ekipp::Preprocessor pp;
pp.registry() = global_registry;  // Copy registry
```

### Limit Recursion Depth

Prevent stack overflow:

```cpp
config.limits.max_expansion_depth = 64;  // Lower for safety
```

### Stream Processing

For large files, process in chunks:

```cpp
std::ifstream input("large_file.txt");
std::string line;
while (std::getline(input, line)) {
    std::string processed = pp.process(line);
    std::cout << processed << '\n';
}
```

## Error Recovery

Implement custom error handling:

```cpp
try {
    output = pp.process(input);
} catch (const ekipp::DirectiveError& e) {
    // Log error but continue
    std::cerr << "Warning: " << e.what() << std::endl;
    output = input;  // Use original input
}
```

## Next Steps

Continue to [Chapter 5: Extending Ekipp](@ref chapter5) to learn how to create sophisticated custom directives.
