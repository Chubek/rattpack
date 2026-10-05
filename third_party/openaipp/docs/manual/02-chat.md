# Chapter 2: Chat Completions

The Chat Completions API is the primary interface for conversational AI. It
accepts a list of messages and returns a model-generated response.

## Low-Level API

The low-level function directly mirrors the OpenAI endpoint:

```cpp
#include <OpenAI.hpp>

namespace low = openapipp::low;

low::HttpClient http(low::from_env());
std::string result = low::chat_completions_create(http, R"({
  "model": "gpt-4o",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is C++20?"}
  ]
})");
```

The function signature is:

```cpp
std::string chat_completions_create(HttpClient &http, std::string body_json);
```

It returns the raw JSON response body. On HTTP errors it throws
`HttpError`.

## High-Level API

The high-level client wraps the endpoint in a typed method:

```cpp
auto client = openapipp::high::Client::from_env();
auto response = client.chat_completions_create_json(body_json);
```

The `ResponseText` struct wraps the JSON string:

```cpp
struct ResponseText {
  std::string json;
};
```

## Message Format

Each message in the `messages` array is a JSON object with at minimum:

- `role`: One of `"system"`, `"user"`, `"assistant"`, `"tool"`, or `"function"`
- `content`: The message text (string or array of content parts)

## Streaming

Streaming chat completions requires setting `"stream": true` in the request
body and using `httplib`'s content receiver. The low-level function returns
the full response; for streaming, use the `HttpClient` directly with a custom
content receiver.

## Error Handling

All HTTP errors are surfaced as `openapipp::low::HttpError`, which inherits
from `std::runtime_error` and carries:

- `http_status`: The HTTP status code (e.g., 429 for rate limits)
- `transport_error`: The `httplib::Error` enum value
- `response_body`: The response body, often containing an error message

## Next Steps

The next chapter covers the Responses API, a newer endpoint that unifies
several capabilities into a single request.
