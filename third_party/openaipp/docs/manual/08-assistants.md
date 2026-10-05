# Chapter 8: Assistants (Beta)

The Assistants API enables building AI agents that can use tools, maintain
conversation threads, and access files. An assistant is a configured agent
with a model, instructions, and optional tools.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// Create an assistant
std::string result = low::assistants_create(http, R"({
  "model": "gpt-4o",
  "name": "Math Tutor",
  "instructions": "You are a personal math tutor.",
  "tools": [{"type": "code_interpreter"}]
})");

// List assistants
std::string list = low::assistants_list(http);

// Retrieve an assistant
std::string assistant = low::assistants_retrieve(http, "asst_abc123");

// Modify an assistant
std::string modified = low::assistants_modify(http, "asst_abc123", R"({
  "name": "Advanced Math Tutor"
})");

// Delete an assistant
std::string deleted = low::assistants_delete(http, "asst_abc123");
```

## Tools

Assistants can use these built-in tools:

- `code_interpreter`: Execute Python code in a sandbox
- `file_search`: Search through uploaded files
- `function`: Call custom functions you define

## Threads and Messages

Assistants work within threads, which store conversation history:

```cpp
// Create a thread
std::string thread = low::threads_create(http);

// Add a message to the thread
std::string msg = low::thread_messages_create(http, thread_id, R"({
  "role": "user",
  "content": "Solve x^2 + 5x + 6 = 0"
})");

// Create a run (execute the assistant on the thread)
std::string run = low::thread_runs_create(http, thread_id, R"({
  "assistant_id": "asst_abc123"
})");
```

## Next Steps

The next chapter covers the Audio API for speech synthesis, transcription,
and translation.
