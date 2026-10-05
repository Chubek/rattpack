# Chapter 7: Fine-tuning

The Fine-tuning API lets you create custom models by training on your own
datasets. The process involves uploading training data, creating a fine-tuning
job, and monitoring progress.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// Create a fine-tuning job
std::string result = low::fine_tuning_jobs_create(http, R"({
  "model": "gpt-4o-2024-08-06",
  "training_file": "file-abc123"
})");

// List all fine-tuning jobs
std::string jobs = low::fine_tuning_jobs_list(http);

// Retrieve a specific job
std::string job = low::fine_tuning_jobs_retrieve(http, "ftjob-abc123");

// Cancel a job
std::string cancel = low::fine_tuning_jobs_cancel(http, "ftjob-abc123");

// List job events
std::string events = low::fine_tuning_jobs_events_list(http, "ftjob-abc123");
```

## Job Lifecycle

A fine-tuning job goes through these states:

1. `validating_files`: Training data is being validated
2. `queued`: Job is waiting for resources
3. `running`: Model is being trained
4. `succeeded`: Training completed successfully
5. `failed`: Training failed
6. `cancelled`: Job was cancelled

## Hyperparameters

Fine-tuning jobs accept optional hyperparameters:

- `n_epochs`: Number of training epochs (default: auto)
- `batch_size`: Batch size for training (default: auto)
- `learning_rate_multiplier`: Learning rate multiplier (default: auto)

## Next Steps

The next chapter covers the Assistants API for building AI agents with tools,
threads, and persistent state.
