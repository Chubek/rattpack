# Chapter 5: Models

The Models API lets you list available models, retrieve model metadata, and
delete fine-tuned models.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// List all models
std::string models = low::models_list(http);

// Retrieve a specific model
std::string model = low::models_retrieve(http, "gpt-4o");

// Delete a fine-tuned model
std::string result = low::models_delete(http, "ft:gpt-3.5-turbo:my-org::abc123");
```

## High-Level API

```cpp
auto client = openapipp::high::Client::from_env();

// List models as JSON string
std::string models_json = client.models_list_json();
```

## Model Object Structure

Each model object in the list response contains:

- `id`: The model identifier (e.g., `"gpt-4o"`)
- `object`: Always `"model"`
- `created`: Unix timestamp of creation
- `owned_by`: The organization that owns the model

## Next Steps

The next chapter covers the Files API for uploading and managing files.
