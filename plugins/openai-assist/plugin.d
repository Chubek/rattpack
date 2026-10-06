module rattpack_assist_openai;

import rattpack.diagnostic : Location, fail;
import rattpack.plugin.abi;
import rattpack.script.evaluator : Evaluator;
import rattpack.script.value : Arguments, Value;
import openai : OpenAiRequest, OpenAiStyle;
import rattpack.serialization : canonical, jsonObject;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

private RattPluginV1 plugin;

pragma(mangle, "rattpack_plugin_entry")
export extern (D) RattPluginV1* rattpack_plugin_entry()
{
    plugin = RattPluginV1.init;
    plugin.kind = PluginKind.stdlib;
    plugin.name = "openai-assist";
    plugin.registerModules = &registerModules;
    return &plugin;
}

/// Register `openai.generate(prompt, model, base_url, api_key, user, password,
/// organization, project, api, timeout)`.
///
/// Credentials are supplied by the host, which resolves them from CLI flags,
/// the environment, and `Rattpack.json` in that order. The function is
/// effectful, so construction-phase graph building cannot reach it.
private void registerModules(Evaluator evaluator)
{
    auto generate = evaluator.native("openai.generate", (Arguments args, Location location) {
        if (evaluator.hermetic)
            fail("E_HERMETIC", "OpenAI requests are unavailable in hermetic actions", location);
        OpenAiRequest request;
        request.baseUrl = args.get("base_url", 1).text(location);
        request.apiKey = args.get("api_key", 2).text(location);
        request.username = args.get("user", 3).text(location);
        request.password = args.get("password", 4).text(location);
        request.organization = args.get("organization", 5).text(location);
        request.project = args.get("project", 6).text(location);
        request.timeoutSeconds = cast(int) args.get("timeout", 9, Value(120)).integer(location);
        if (request.timeoutSeconds <= 0)
            fail("E_CLI", "OpenAI timeout must be a positive number of seconds", location);
        request.userAgent = "rattspec-assist";
        if (!request.baseUrl.length)
            fail("E_ASSIST", "no OpenAI base URL; set --openai-url, OPENAI_BASE,"
                    ~ " or openai.base_url in Rattpack.json", location);
        if (!request.apiKey.length && !request.username.length)
            fail("E_ASSIST", "no OpenAI credentials; set an API key or a user and"
                    ~ " password", location);
        auto style = args.get("api", 8, Value("chat")).text(location);
        if (style == "responses")
            request.style = OpenAiStyle.responses;
        else if (style == "chat")
            request.style = OpenAiStyle.chat;
        else
            fail("E_CLI", "unknown OpenAI API '" ~ style
                    ~ "'; use chat or responses", location);
        auto model = args.get("model", 7).text(location);
        if (!model.length)
            fail("E_ASSIST", "no OpenAI model selected", location);
        request.body = canonical(requestBody(style, model,
                args.get("prompt", 0).text(location)));
        return Value(assistantText(request.send(), location));
    }, true);
    evaluator.modules["openai"] = Value(["generate": generate]);
}

/// Build the request body for the selected endpoint family.
private JSONValue requestBody(string style, string model, string prompt)
{
    auto body = jsonObject();
    body["model"] = JSONValue(model);
    if (style == "responses")
    {
        body["input"] = JSONValue(prompt);
        return body;
    }
    auto message = jsonObject();
    message["role"] = JSONValue("user");
    message["content"] = JSONValue(prompt);
    body["messages"] = JSONValue([message]);
    return body;
}

/// Extract assistant text from either endpoint family.
///
/// Chat completions nest it under choices[0].message.content; the Responses API
/// offers output_text and, failing that, output[].content[].text.
private string assistantText(string response, Location location)
{
    JSONValue document;
    try
    {
        document = parseJSON(response);
    }
    catch (Exception)
    {
        fail("E_ASSIST", "OpenAI returned a response that is not JSON", location);
    }
    if (document.type != JSONType.object)
        fail("E_ASSIST", "OpenAI response is not a JSON object", location);
    auto root = document.objectNoRef;
    if (auto error = "error" in root)
    {
        import std.json : JSONValue;

        auto reason = error.type == JSONType.object && "message" in error.objectNoRef
                ? (*("message" in error.objectNoRef)).str : (*error).str;
        fail("E_ASSIST", "OpenAI reported an error: " ~ reason, location);
    }
    if (auto output = "output_text" in root)
        if ((*output).type == JSONType.string && (*output).str.strip.length)
            return (*output).str;
    if (auto choices = "choices" in root)
    {
        auto entries = (*choices).array;
        if (entries.length)
        {
            auto choice = entries[0];
            if (choice.type == JSONType.object)
                if (auto message = "message" in choice.objectNoRef)
                    if ((*message).type == JSONType.object)
                        if (auto content = "content" in (*message).objectNoRef)
                            if ((*content).type == JSONType.string && (*content).str.strip.length)
                                return (*content).str;
        }
    }
    if (auto output = "output" in root)
        foreach (item; (*output).array)
        {
            if (item.type != JSONType.object)
                continue;
            auto fields = item.objectNoRef;
            auto content = "content" in fields;
            if (content is null)
                continue;
            foreach (part; (*content).array)
            {
                if (part.type != JSONType.object)
                    continue;
                auto text = "text" in part.objectNoRef;
                if (text !is null && (*text).type == JSONType.string
                        && (*text).str.strip.length)
                    return (*text).str;
            }
        }
    fail("E_ASSIST", "no assistant text in the OpenAI response", location);
    return null;
}