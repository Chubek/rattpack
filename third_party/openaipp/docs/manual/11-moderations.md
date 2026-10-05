# Chapter 11: Moderations

The Moderations API classifies text for potentially harmful content across
multiple categories.

## Low-Level API

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

std::string result = low::moderations_create(http, R"({
  "input": "I want to learn about science."
})");
```

## Moderation Categories

The API checks for content in these categories:

- `hate`: Content that expresses or promotes hate
- `hate/threatening`: Hateful content with threats of violence
- `harassment`: Harassing content targeting individuals
- `harassment/threatening`: Harassment with threats
- `self-harm`: Content promoting self-harm
- `self-harm/intent`: Content indicating intent of self-harm
- `self-harm/instructions`: Content instructing self-harm
- `sexual`: Sexually explicit content
- `sexual/minors`: Sexual content involving minors
- `violence`: Content depicting violence
- `violence/graphic`: Graphic depictions of violence

## Response Format

Each category in the response includes:

- `flagged`: Boolean indicating if the content was flagged
- `category_scores`: Confidence scores (0.0 to 1.0) for each category

## Next Steps

The final chapter covers advanced topics including Batch API, Evals,
Conversations, and the Organization API.
