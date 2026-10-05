# Chapter 4: Embeddings

The Embeddings API converts text into vector representations that capture
semantic meaning. These vectors can be used for search, clustering,
classification, and recommendation systems.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());
std::string result = low::embeddings_create(http, R"({
  "model": "text-embedding-3-small",
  "input": "The quick brown fox jumps over the lazy dog"
})");
```

## High-Level API

```cpp
auto client = openapipp::high::Client::from_env();
auto response = client.embeddings_create_json(body_json);
// response.json contains the embedding vectors
```

## Available Models

| Model | Dimensions | Max Input |
|---|---|---|
| `text-embedding-3-small` | 512, 1536 | 8191 tokens |
| `text-embedding-3-large` | 256, 1024, 3072 | 8191 tokens |
| `text-embedding-ada-002` | 1536 | 8191 tokens |

Use the `dimensions` parameter to request a specific output size for
`text-embedding-3-*` models.

## Batch Embeddings

The `input` field accepts a string or an array of strings. When passing an
array, the response contains an embedding for each input string in the same
order.

## Next Steps

The next chapter covers the Models API for listing and retrieving model
information.
