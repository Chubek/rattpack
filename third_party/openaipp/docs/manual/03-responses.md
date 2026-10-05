# Chapter 3: Responses API

The Responses API is a unified endpoint that combines chat, tool use, and
structured output capabilities into a single request.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());
std::string result = low::responses_create(http, R"({
  "model": "gpt-4o",
  "input": "What is the capital of France?",
  "tools": [
    {
      "type": "web_search"
    }
  ]
})");
```

The function signature is:

```cpp
std::string responses_create(HttpClient &http, std::string body_json);
```

## High-Level API

```cpp
auto client = openapipp::high::Client::from_env();
auto response = client.responses_create_json(body_json);
// response.json contains the parsed JSON response
```

## Key Differences from Chat Completions

- **Input format**: The `input` field accepts both a plain string and a
  structured array of content parts.
- **Tool integration**: Built-in tools like `web_search`, `file_search`, and
  `code_interpreter` are configured directly in the request.
- **Structured output**: The `text` field in the response contains a `format`
  sub-field for specifying output structure.

## Response Format

The response includes:

- `id`: Unique response identifier
- `output`: Array of output items (messages, tool calls, etc.)
- `usage`: Token usage statistics
- `status`: Processing status (`"completed"`, `"failed"`, etc.)

## Next Steps

The next chapter covers the Embeddings API for generating vector
representations of text.
