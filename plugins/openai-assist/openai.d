module openai;

import rattpack.diagnostic : fail;
import std.string : fromStringz, strip, toStringz;

/// C ABI connection and credential settings. Strings are optional except baseURL.
struct COpenAiConfig
{
    const(char)* baseUrl;
    const(char)* apiKey;
    const(char)* organization;
    const(char)* project;
    const(char)* userAgent;
    const(char)* username;
    const(char)* password;
    int timeoutSeconds;
}

enum OpenAiStyle : int
{
    chat = 0,
    responses = 1
}

extern (C)
{
    /// Returns a malloc'd response body released with ratt_openai_free, or null.
    char* ratt_openai_request(const COpenAiConfig* config, const(char)* body,
            int style, char* error, size_t errorSize);
    /// Release a buffer returned by ratt_openai_request.
    void ratt_openai_free(void* pointer);
    /// Bridge format version; a mismatch indicates a stale native archive.
    uint ratt_openai_bridge_version();
}

enum uint openAiBridgeVersion = 1;

/// True when the native bridge is linked in and reports the expected version.
bool openAiAvailable()
{
    return ratt_openai_bridge_version() == openAiBridgeVersion;
}

/// One completed request against an OpenAI-compatible endpoint.
///
/// Callers resolve credentials from the environment, `Rattpack.json`, and CLI
/// flags. This module owns transport, timeouts, and error reporting only.
struct OpenAiRequest
{
    string baseUrl;
    string apiKey;
    string organization;
    string project;
    string userAgent;
    string username;
    string password;
    int timeoutSeconds = 120;
    OpenAiStyle style = OpenAiStyle.chat;
    /// Complete request body; the caller builds the OpenAI request JSON.
    string body;

    // TRUSTED: the C bridge reads these NUL-terminated buffers synchronously
    // and retains no pointer past the call; the conversions are kept alive for
    // the whole request so no pointer outlives its buffer.
    string send() @trusted
    {
        if (!openAiAvailable())
            fail("E_ASSIST", "the OpenAI assist bridge is missing or stale;"
                    ~ " rebuild the native archive with tools/build-native.py");
        auto base = toStringz(baseUrl);
        auto key = toStringz(apiKey);
        auto organization_ = toStringz(organization);
        auto project_ = toStringz(project);
        auto agent = toStringz(userAgent);
        auto user = toStringz(username);
        auto secret = toStringz(password);
        auto payload = toStringz(body);
        COpenAiConfig config;
        config.baseUrl = base;
        // An empty credential must not become a non-null pointer, which the C
        // side would treat as a present-but-empty header value.
        config.apiKey = apiKey.length ? key : null;
        config.organization = organization.length ? organization_ : null;
        config.project = project.length ? project_ : null;
        config.userAgent = userAgent.length ? agent : null;
        config.username = username.length ? user : null;
        config.password = password.length ? secret : null;
        config.timeoutSeconds = timeoutSeconds;
        char[1024] reason;
        auto response = ratt_openai_request(&config, payload, cast(int) style,
                reason.ptr, reason.length);
        if (response is null)
            fail("E_ASSIST", "OpenAI request failed: " ~ fromStringz(reason.ptr).strip.idup);
        scope (exit)
            ratt_openai_free(response);
        return fromStringz(response).idup;
    }
}