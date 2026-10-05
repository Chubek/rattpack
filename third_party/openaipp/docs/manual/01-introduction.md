# Chapter 1: Introduction to OpenAIpp

OpenAIpp is a header-only C++20 library that provides a complete, type-safe
client for the OpenAI API. It is organized in three layers, each building on
the one below it, so you can work at the level of abstraction that fits your
use case.

## Why OpenAIpp?

Most OpenAI C++ wrappers are thin HTTP clients that return raw JSON strings.
OpenAIpp takes a different approach:

- **Low-level layer** (`openapipp::low`): One function per OpenAI endpoint,
  taking plain parameters and returning parsed `nlohmann::json`. Always
  matches the schema in `third_party/openai-openapi`.
- **High-level layer** (`openapipp::high`): Typed structs and enums wrapping
  the low-level layer. Request and response bodies become C++ types, and
  endpoints become methods on client classes.
- **DSL layer** (`openapipp::dsl`): A fluent, composable DSL built on top of
  DSLtk. Provides pipe-based request chaining, monadic error handling, and
  compile-time pattern matching.

## Quick Start

```cpp
#include <OpenAI.hpp>

int main() {
  // Use the high-level client
  auto client = openapipp::high::Client::from_env();

  // List available models
  std::string models_json = client.models_list_json();

  // Create a chat completion
  using namespace nlohmann;
  json body = {
    {"model", "gpt-4o"},
    {"messages", json::array({
      {{"role", "user"}, {"content", "Hello!"}}
    })}
  };
  auto response = client.chat_completions_create_json(body.dump());
}
```

## Installation

OpenAIpp is header-only and builds with CMake:

```bash
git clone https://github.com/example/openaipp.git
cd openaipp
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make install
```

### Dependencies

| Dependency | Role |
|---|---|
| cpp-httplib | HTTP client |
| nlohmann-json | JSON parsing |
| MetaTk/DSLtk | DSL toolkit for `openapipp::dsl` |

All dependencies are vendored under `third_party/`.

## Environment Variables

Set these before using `Client::from_env()`:

| Variable | Purpose |
|---|---|
| `OPENAI_API_KEY` | Your API key |
| `OPENAI_BASE` | Base URL (defaults to `https://api.openai.com`) |
| `OPENAI_ORG_ID` | Organization ID (optional) |
| `OPENAI_PROJECT_ID` | Project ID (optional) |
| `OPENAI_USER_AGENT` | Custom user-agent string |

## Next Steps

In the following chapters we will explore each API category in detail, starting
with Chat Completions.
