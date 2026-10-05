# Chapter 5: Extending Ekipp {#chapter5}

## Creating Custom Directives

### Basic Directive

The simplest directive:

```cpp
auto hello = ekipp::Directive::fluent()
    << ekipp::Directive::Name("hello")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
        return "Hello, " + args.raw(0) + "!";
    });

pp.registry().registerDirective(hello);
```

### Directive with Validation

Add input validation:

```cpp
auto positive = ekipp::Directive::fluent()
    << ekipp::Directive::Name("positive")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Validator([](const ekipp::Arguments& args) {
        int value = args.get<int>(0);
        if (value <= 0) {
            throw ekipp::DirectiveError("value must be positive");
        }
    })
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
        return "Valid positive: " + args.raw(0);
    });
```

### Stateful Directive

Maintain state across invocations:

```cpp
int counter = 0;

auto increment = ekipp::Directive::fluent()
    << ekipp::Directive::Name("counter")
    << ekipp::Directive::NumParams(0)
    << ekipp::Directive::Semantics([&counter](ekipp::Arguments&, ekipp::Context&) {
        return std::to_string(++counter);
    });

// @counter()@ => 1
// @counter()@ => 2
// @counter()@ => 3
```

### Context-Aware Directive

Access preprocessor state:

```cpp
auto macro_list = ekipp::Directive::fluent()
    << ekipp::Directive::Name("list_macros")
    << ekipp::Directive::NumParams(0)
    << ekipp::Directive::Semantics([](ekipp::Arguments&, ekipp::Context& ctx) {
        if (!ctx.symbols) return std::string("No symbol table");
        
        std::ostringstream oss;
        for (const auto& [name, macro] : ctx.symbols->all()) {
            oss << name << "\n";
        }
        return oss.str();
    });
```

## Advanced Directive Patterns

### Conditional Directive

```cpp
auto ifdef = ekipp::Directive::fluent()
    << ekipp::Directive::Name("ifdef")
    << ekipp::Directive::MinParams(2)
    << ekipp::Directive::MaxParams(3)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context& ctx) {
        std::string macro_name = args.raw(0);
        std::string if_defined = args.raw(1);
        std::string if_not_defined = args.size() > 2 ? args.raw(2) : "";
        
        return ctx.symbols && ctx.symbols->find(macro_name) 
            ? if_defined 
            : if_not_defined;
    });

// Usage: @ifdef(DEBUG, "Debug mode", "Release mode")@
```

### Loop Directive

```cpp
auto repeat = ekipp::Directive::fluent()
    << ekipp::Directive::Name("repeat")
    << ekipp::Directive::NumParams(2)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
        int count = args.get<int>(0);
        std::string text = args.raw(1);
        
        std::ostringstream oss;
        for (int i = 0; i < count; ++i) {
            oss << text;
        }
        return oss.str();
    });

// Usage: @repeat(3, "Hello ")@ => "Hello Hello Hello "
```

### File Processing Directive

```cpp
auto read_lines = ekipp::Directive::fluent()
    << ekipp::Directive::Name("read_lines")
    << ekipp::Directive::NumParams(1)
    << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
        std::ifstream file(args.raw(0));
        if (!file) {
            throw ekipp::DirectiveError("Cannot open file: " + args.raw(0));
        }
        
        std::ostringstream oss;
        std::string line;
        int line_num = 1;
        while (std::getline(file, line)) {
            oss << line_num++ << ": " << line << "\n";
        }
        return oss.str();
    });
```

## Building a Directive Library

### Organizing Directives

Create a namespace for your directives:

```cpp
namespace my_directives {

inline ekipp::Directive make_upper() {
    return ekipp::Directive::fluent()
        << ekipp::Directive::Name("upper")
        << ekipp::Directive::NumParams(1)
        << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
            std::string s = args.raw(0);
            std::transform(s.begin(), s.end(), s.begin(), ::toupper);
            return s;
        });
}

inline ekipp::Directive make_lower() {
    return ekipp::Directive::fluent()
        << ekipp::Directive::Name("lower")
        << ekipp::Directive::NumParams(1)
        << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
            std::string s = args.raw(0);
            std::transform(s.begin(), s.end(), s.begin(), ::tolower);
            return s;
        });
}

inline void register_all(ekipp::DirectiveRegistry& registry) {
    registry.registerDirective(make_upper());
    registry.registerDirective(make_lower());
}

} // namespace my_directives
```

### Directive Factory Pattern

```cpp
class DirectiveFactory {
public:
    static ekipp::Directive create_string_transform(
        const std::string& name,
        std::function<std::string(const std::string&)> transform)
    {
        return ekipp::Directive::fluent()
            << ekipp::Directive::Name(name)
            << ekipp::Directive::NumParams(1)
            << ekipp::Directive::Semantics(
                [transform](ekipp::Arguments& args, ekipp::Context&) {
                    return transform(args.raw(0));
                });
    }
};

// Create multiple similar directives
auto upper = DirectiveFactory::create_string_transform("upper", 
    [](const std::string& s) {
        std::string result = s;
        std::transform(result.begin(), result.end(), result.begin(), ::toupper);
        return result;
    });
```

## Template-Based DSL

Create a compile-time DSL using templates:

```cpp
template<typename Func>
class DirectiveBuilder {
    std::string name_;
    Func func_;
    
public:
    DirectiveBuilder(std::string name, Func func)
        : name_(std::move(name)), func_(std::move(func)) {}
    
    ekipp::Directive build() const {
        return ekipp::Directive::fluent()
            << ekipp::Directive::Name(name_)
            << ekipp::Directive::Semantics(
                [f = func_](ekipp::Arguments& args, ekipp::Context& ctx) {
                    return f(args, ctx);
                });
    }
};

template<typename Func>
auto make_directive(std::string name, Func func) {
    return DirectiveBuilder<Func>(std::move(name), std::move(func));
}

// Usage:
auto my_dir = make_directive("test", 
    [](ekipp::Arguments& args, ekipp::Context&) {
        return "Result: " + args.raw(0);
    }).build();
```

## CRTP-Based Directives

Use CRTP for zero-cost abstraction:

```cpp
template<typename Derived>
class DirectiveBase {
public:
    ekipp::Directive create() {
        return ekipp::Directive::fluent()
            << ekipp::Directive::Name(static_cast<Derived*>(this)->name())
            << ekipp::Directive::Semantics(
                [this](ekipp::Arguments& args, ekipp::Context& ctx) {
                    return static_cast<Derived*>(this)->execute(args, ctx);
                });
    }
};

class UpperDirective : public DirectiveBase<UpperDirective> {
public:
    static constexpr const char* name() { return "upper"; }
    
    std::string execute(ekipp::Arguments& args, ekipp::Context&) {
        std::string s = args.raw(0);
        std::transform(s.begin(), s.end(), s.begin(), ::toupper);
        return s;
    }
};

// Usage:
UpperDirective upper_dir;
pp.registry().registerDirective(upper_dir.create());
```

## Compile-Time Directive Registration

Use constexpr for compile-time validation:

```cpp
template<size_t N>
struct DirectiveSpec {
    const char* name;
    size_t min_params;
    size_t max_params;
    
    constexpr DirectiveSpec(const char* n, size_t min, size_t max)
        : name(n), min_params(min), max_params(max) {}
};

constexpr DirectiveSpec specs[] = {
    {"upper", 1, 1},
    {"lower", 1, 1},
    {"repeat", 2, 2}
};

// Validate at compile time
static_assert(specs[0].min_params <= specs[0].max_params);
```

## Plugin System

Create a plugin architecture:

```cpp
class DirectivePlugin {
public:
    virtual ~DirectivePlugin() = default;
    virtual std::vector<ekipp::Directive> directives() const = 0;
    virtual std::string name() const = 0;
    virtual std::string version() const = 0;
};

class PluginManager {
    std::vector<std::unique_ptr<DirectivePlugin>> plugins_;
    
public:
    void load_plugin(std::unique_ptr<DirectivePlugin> plugin) {
        plugins_.push_back(std::move(plugin));
    }
    
    void register_all(ekipp::DirectiveRegistry& registry) {
        for (const auto& plugin : plugins_) {
            for (const auto& directive : plugin->directives()) {
                registry.registerDirective(directive);
            }
        }
    }
};
```

## Testing Custom Directives

```cpp
#include <cassert>

void test_upper_directive() {
    ekipp::Preprocessor pp;
    
    auto upper = ekipp::Directive::fluent()
        << ekipp::Directive::Name("upper")
        << ekipp::Directive::NumParams(1)
        << ekipp::Directive::Semantics([](ekipp::Arguments& args, ekipp::Context&) {
            std::string s = args.raw(0);
            std::transform(s.begin(), s.end(), s.begin(), ::toupper);
            return s;
        });
    
    pp.registry().registerDirective(upper);
    
    std::string input = "@upper(hello)@";
    std::string output = pp.process(input);
    
    assert(output == "HELLO");
}
```

## Best Practices

1. **Keep directives focused** - One directive, one responsibility
2. **Validate inputs** - Check arguments before processing
3. **Handle errors gracefully** - Throw descriptive exceptions
4. **Document directives** - Use Description and Category
5. **Test thoroughly** - Unit test each directive
6. **Consider performance** - Avoid expensive operations in hot paths
7. **Use const correctness** - Mark read-only operations as const
8. **Namespace your directives** - Avoid name collisions

## Conclusion

Ekipp provides a powerful foundation for building custom text processing tools. By combining directives, macros, and embedding hooks, you can create sophisticated preprocessing systems tailored to your specific needs.

For more examples, see the `examples/` directory in the Ekipp distribution.
