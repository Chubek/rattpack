# Chapter 6: Files and Uploads

The Files API manages file uploads for fine-tuning, assistants, and other
file-based operations.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// List all files
std::string files = low::files_list(http);

// Delete a file
std::string result = low::files_delete(http, "file-abc123");
```

## File Purpose

When uploading a file, specify its purpose:

- `"fine-tune"`: For fine-tuning training data
- `"assistants"`: For use with the Assistants API
- `"batch"`: For batch API input files
- `"vision"`: For vision-related files

## File Operations

The low-level API supports:

- `files_list`: List all uploaded files
- `files_delete`: Delete a file by ID

For file upload and content retrieval, use the `HttpClient` directly with
multipart form data, as the file content is binary.

## Next Steps

The next chapter covers the Fine-tuning API for creating custom models.
