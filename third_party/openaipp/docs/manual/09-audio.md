# Chapter 9: Audio

The Audio API provides speech synthesis (text-to-speech), transcription
(speech-to-text), and translation capabilities.

## Speech (Text-to-Speech)

The speech endpoint generates audio from text:

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// The speech endpoint returns binary audio data, not JSON.
// Use the HttpClient directly for streaming the response.
```

Available voices include `"alloy"`, `"echo"`, `"fable"`, `"onyx"`, `"nova"`,
and `"shimmer"`. Supported formats are `mp3`, `opus`, `aac`, `flac`, `wav`,
and `pcm`.

## Transcriptions

The transcriptions endpoint converts audio to text:

```cpp
// Transcribe audio using Whisper models
// POST /audio/transcriptions with multipart form data
```

The `model` parameter accepts `whisper-1`. Supported input formats include
`mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `wav`, and `webm`.

## Translations

The translations endpoint translates audio to English text:

```cpp
// Translate non-English audio to English
// POST /audio/translations with multipart form data
```

## Voices

The voices API lists available text-to-speech voices:

```cpp
// List available voices
// GET /audio/voices
```

## Next Steps

The next chapter covers the Images API for generating, editing, and
creating variations of images.
