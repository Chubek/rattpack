# OpenAIpp

OpenAIpp is a header-only C++20 library that provides a complete, type-safe
client for the OpenAI API. It is organized in three layers, each building on the
one below it, so you can work at the level of abstraction that fits your use
case.

## Three Layers

### `openapipp::low` — Raw Endpoints

Implements every endpoint naively: one function per OpenAI endpoint, taking
plain parameters, performing the HTTP call via cpp-httplib, and returning the
parsed `nlohmann::json`. When adding or changing an endpoint, always match the
schema in `third_party/openai-openapi` — that spec is authoritative, not the
docs or existing code.

### `openapipp::high` — Typed Interface

Wraps the low level with classes, structs, and enums. Request/response bodies
become structs, string enums become C++ enums, and endpoints become methods on
client classes. Every high-level construct delegates to `openapipp::low`;
do not duplicate HTTP or JSON logic here.

### `openapipp::dsl` — C++-Native DSL

Provides a fluent, composable DSL on top of `openapipp::high`, built with
`third_party/MetaTk/DSLtk/DSLtk.hpp`. The DSL is a set of composable feature
mixins attached to a CRTP base, supporting pipe-based request chaining, monadic
error handling, and compile-time pattern matching.

## Quick Example

```cpp
#include <OpenAI.hpp>

int main() {
  auto client = openapipp::high::Client::from_env();

  // High-level: simple chat completion
  auto response = client.chat_completions_create_json(R"({
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  })");

  // DSL: pipe-based model listing
  auto models = client | openapipp::dsl::models_list();
}
```

## Dependencies

| Dependency | Location | Role |
|---|---|---|
| cpp-httplib | `third_party/cpp-httplib` | HTTP client |
| openai-openapi | `third_party/openai-openapi` | API source of truth |
| nlohmann-json | `third_party/nlohmann-json` | JSON parsing |
| MetaTk/DSLtk | `third_party/MetaTk/DSLtk/DSLtk.hpp` | DSL toolkit for `openapipp::dsl` |

## Manual

The OpenAIpp manual is divided into twelve chapters covering every aspect of the library:

1. [Introduction to OpenAIpp](manual/01-introduction.md)
2. [Chat Completions](manual/02-chat.md)
3. [Responses API](manual/03-responses.md)
4. [Embeddings](manual/04-embeddings.md)
5. [Models](manual/05-models.md)
6. [Files and Uploads](manual/06-files.md)
7. [Fine-tuning](manual/07-fine-tuning.md)
8. [Assistants (Beta)](manual/08-assistants.md)
9. [Audio](manual/09-audio.md)
10. [Images](manual/10-images.md)
11. [Moderations](manual/11-moderations.md)
12. [Advanced Topics](manual/12-advanced.md)

## License

OpenAIpp is released under the MIT License.
