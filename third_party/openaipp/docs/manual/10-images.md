# Chapter 10: Images

The Images API provides endpoints for generating images from text prompts,
editing existing images, and creating variations.

## Image Generations

Create images from text descriptions using DALL-E models:

```cpp
namespace low = openapipp::low;

low::HttpClient http(low::from_env());

// Generate an image
std::string result = low::images_generations_create(http, R"({
  "model": "dall-e-3",
  "prompt": "A serene mountain landscape at sunset",
  "n": 1,
  "size": "1024x1024"
})");
```

The response includes a `data` array with image URLs or base64-encoded data.

## Image Quality and Size

DALL-E 3 supports:

- **Quality**: `"standard"` or `"hd"`
- **Sizes**: `1024x1024`, `1792x1024`, `1024x1792`
- **Style**: `"vivid"` or `"natural"`

DALL-E 2 supports:

- **Sizes**: `256x256`, `512x512`, `1024x1024`

## Image Edits

Modify parts of an existing image using a mask:

```cpp
// POST /images/edits with multipart form data
// Requires: image, prompt, and optional mask
```

## Image Variations

Create variations of an existing image:

```cpp
// POST /images/variations with multipart form data
// Requires: image
```

## Next Steps

The next chapter covers the Moderations API for content safety classification.
