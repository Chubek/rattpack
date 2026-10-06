// C ABI bridge over the vendored openaipp OpenAI client.
//
// openaipp models bearer-token authentication only, so HTTP Basic credentials
// are applied by the same cpp-httplib client it already uses. URL parsing,
// header construction, and both endpoint calls stay inside openaipp.
#include <OpenAI.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {

/// Connection and credential settings. Every string is optional except base_url.
struct ratt_openai_config
{
    const char *base_url;
    const char *api_key;
    const char *organization;
    const char *project;
    const char *user_agent;
    const char *username;
    const char *password;
    int timeout_seconds;
};

/// Endpoint families openaipp exposes.
enum ratt_openai_style
{
    RATT_OPENAI_CHAT = 0,
    RATT_OPENAI_RESPONSES = 1
};

/// Bounded so a hostile or misconfigured server cannot exhaust host memory.
static const std::size_t max_response_bytes = 64u * 1024u * 1024u;

static std::string
text_of (const char *value)
{
    return value != nullptr ? std::string (value) : std::string{};
}

static void
report (char *error, std::size_t error_size, const std::string &message)
{
    if (error != nullptr && error_size > 0)
        std::snprintf (error, error_size, "%s", message.c_str ());
}

/// Copy a response body into a malloc'd buffer owned by the caller.
static char *
own (const std::string &body)
{
    if (body.size () > max_response_bytes)
        return nullptr;
    char *buffer = static_cast<char *> (std::malloc (body.size () + 1));
    if (buffer == nullptr)
        return nullptr;
    std::memcpy (buffer, body.data (), body.size ());
    buffer[body.size ()] = '\0';
    return buffer;
}

/// Perform one OpenAI-compatible request and return the raw response body.
///
/// Returns a malloc'd buffer the caller releases with ratt_openai_free, or
/// nullptr with a human-readable reason in `error`.
char *
ratt_openai_request (const ratt_openai_config *config, const char *body,
                     int style, char *error, std::size_t error_size)
{
    if (config == nullptr || body == nullptr)
    {
        report (error, error_size, "null request configuration");
        return nullptr;
    }

    try
    {
        // ClientConfig's default member initializers build std::string members
        // straight from getenv, which throws when a variable is unset. Aggregate
        // initialization supplies every member and skips those initializers.
        openapipp::low::ClientConfig settings{
            text_of (config->base_url),   // base_url
            text_of (config->api_key),   // api_key
            text_of (config->organization), // organization
            text_of (config->project),   // project
            text_of (config->user_agent), // user_agent
            config->timeout_seconds > 0 ? config->timeout_seconds : 60};
        const int timeout_seconds = settings.timeout_seconds;

        // openaipp rejects an empty or scheme-less base URL before any I/O.
        const auto url = openapipp::low::parse_base_url (settings.base_url);
        const std::string request = text_of (body);
        const std::string username = text_of (config->username);
        const std::string password = text_of (config->password);

        if (!username.empty () || !password.empty ())
        {
            // Basic credentials: reuse openaipp's URL parse and header set,
            // then let cpp-httplib attach the Authorization header itself.
            httplib::Client client (url.scheme + "://" + url.host + ":"
                                    + std::to_string (url.port));
            client.set_read_timeout (timeout_seconds, 0);
            client.set_write_timeout (timeout_seconds, 0);
            client.set_connection_timeout (timeout_seconds, 0);
            client.set_basic_auth (username, password);
            auto headers = openapipp::low::default_headers (settings);
            // Bearer credentials would override the Basic header above.
            headers.erase ("Authorization");
            const std::string path
                = url.base_path
                  + (style == RATT_OPENAI_RESPONSES ? "/responses"
                                                   : "/chat/completions");
            const auto result = client.Post (path, headers, request,
                                             "application/json");
            if (!result)
            {
                report (error, error_size,
                        "transport error: "
                            + std::string (httplib::to_string (result.error ())));
                return nullptr;
            }
            if (result->status < 200 || result->status >= 300)
            {
                report (error, error_size,
                        "http error: status=" + std::to_string (result->status)
                            + " " + result->body.substr (0, 2048));
                return nullptr;
            }
            return own (result->body);
        }

        openapipp::low::HttpClient http (std::move (settings));
        const std::string response
            = (style == RATT_OPENAI_RESPONSES)
                  ? openapipp::low::responses_create (http, request)
                  : openapipp::low::chat_completions_create (http, request);
        return own (response);
    }
    catch (const openapipp::low::HttpError &failure)
    {
        report (error, error_size,
                "http error: status=" + std::to_string (failure.http_status)
                    + " " + failure.response_body.substr (0, 2048));
    }
    catch (const std::exception &failure)
    {
        report (error, error_size, failure.what ());
    }
    return nullptr;
}

void
ratt_openai_free (void *pointer)
{
    std::free (pointer);
}

/// Report the bridge format version so the host can detect a stale build.
unsigned
ratt_openai_bridge_version (void)
{
    return 1;
}

} // extern "C"