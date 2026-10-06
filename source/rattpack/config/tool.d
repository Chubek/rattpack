module rattpack.config.tool;

import rattpack.diagnostic : fail;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;

/// Backend used by `rattspec assist`.
enum AssistBackend : string
{
    opencode = "opencode",
    openai = "openai"
}

private static immutable backendNames = ["opencode", "openai"];

/// std.json spells booleans true_/false_; treat anything else as absent.
private bool boolOr(JSONValue value, bool fallback) @safe
{
    if (value.type == JSONType.true_)
        return true;
    if (value.type == JSONType.false_)
        return false;
    return fallback;
}

/// OpenCode V2 settings. The plugin drives the `opencode` CLI, which owns
/// service discovery and authentication.
struct OpenCodeSettings
{
    string executable = "opencode";
    string server;
    string model;
    uint timeout = 120;
    /// Launch with a private server instead of the shared background service.
    bool standalone = true;
}

/// Settings for any server speaking the OpenAI API.
struct OpenAiSettings
{
    string baseUrl = "https://api.openai.com/v1";
    string apiKey;
    string user;
    string password;
    string organization;
    string project;
    string model;
    uint timeout = 120;
    /// "chat" uses /chat/completions, "responses" uses /responses.
    string api = "chat";
}

/// Directory map settings.
struct MapSettings
{
    /// Include directory file and byte totals in the rendered text.
    bool summary = true;
    /// Hard cap on mapped entries, protecting against pathological trees.
    uint maxEntries = 200_000;
}

/// Tooling configuration read from `$XDG_CONFIG_HOME/rattpack/Rattpack.json`.
///
/// This configures host tooling: which assist backend to use, plugin and
/// script locations, and external commands. It is deliberately separate from
/// `Config.toml`, which is build configuration exposed read-only to Rattscript;
/// no build graph reads this file.
struct ToolConfig
{
    AssistBackend backend = AssistBackend.opencode;
    OpenCodeSettings opencode;
    OpenAiSettings openai;
    /// Plugin library overrides, by plugin name.
    string[string] plugins;
    /// Script locations used by tooling commands.
    string[string] scripts;
    /// External commands used by tooling commands.
    string[string] commands;
    MapSettings map;
}

/// Configuration file name inside the Rattpack configuration directory.
enum string toolConfigName = "Rattpack.json";

/// Read `Rattpack.json` from a configuration directory. A missing file yields
/// defaults; malformed JSON is a configuration error, not a crash.
ToolConfig loadToolConfig(string configDirectory) @safe
{
    ToolConfig config;
    auto path = buildPath(configDirectory, toolConfigName);
    if (!exists(path))
        return config;
    JSONValue document;
    try
    {
        document = parseJSON(readText(path));
    }
    catch (Exception error)
    {
        fail("E_CONFIG", "cannot parse " ~ path ~ ": " ~ error.msg);
    }
    if (document.type != JSONType.object)
        fail("E_CONFIG", path ~ " must contain a JSON object");
    auto root = document.objectNoRef;
    if (auto entry = "backend" in root)
    {
        auto name = entry.str;
        if (!backendNames.canFind(name))
            fail("E_CONFIG", "unknown assist backend '" ~ name ~ "' in " ~ path
                    ~ "; use opencode or openai");
        config.backend = cast(AssistBackend) name;
    }
    if (auto section = "opencode" in root)
        config.opencode = readOpenCode(*section, path);
    if (auto section = "openai" in root)
        config.openai = readOpenAi(*section, path);
    if (auto section = "plugins" in root)
        config.plugins = readStringTable(*section, path);
    if (auto section = "scripts" in root)
        config.scripts = readStringTable(*section, path);
    if (auto section = "commands" in root)
        config.commands = readStringTable(*section, path);
    if (auto section = "map" in root)
        config.map = readMap(*section, path);
    return config;
}

private OpenCodeSettings readOpenCode(JSONValue section, string path) @safe
{
    OpenCodeSettings settings;
    if (section.type != JSONType.object)
        fail("E_CONFIG", "'opencode' in " ~ path ~ " must be an object");
    auto values = section.objectNoRef;
    if (auto value = "executable" in values)
        settings.executable = text(*value, "opencode.executable", path);
    if (auto value = "server" in values)
        settings.server = text(*value, "opencode.server", path);
    if (auto value = "model" in values)
        settings.model = text(*value, "opencode.model", path);
    if (auto value = "timeout" in values)
        settings.timeout = positiveNumber(*value, "opencode.timeout", path);
    if (auto value = "standalone" in values)
        settings.standalone = boolOr(*value, true);
    return settings;
}

private OpenAiSettings readOpenAi(JSONValue section, string path) @safe
{
    OpenAiSettings settings;
    if (section.type != JSONType.object)
        fail("E_CONFIG", "'openai' in " ~ path ~ " must be an object");
    auto values = section.objectNoRef;
    if (auto value = "base_url" in values)
        settings.baseUrl = text(*value, "openai.base_url", path);
    if (auto value = "api_key" in values)
        settings.apiKey = text(*value, "openai.api_key", path);
    if (auto value = "user" in values)
        settings.user = text(*value, "openai.user", path);
    if (auto value = "password" in values)
        settings.password = text(*value, "openai.password", path);
    if (auto value = "organization" in values)
        settings.organization = text(*value, "openai.organization", path);
    if (auto value = "project" in values)
        settings.project = text(*value, "openai.project", path);
    if (auto value = "model" in values)
        settings.model = text(*value, "openai.model", path);
    if (auto value = "api" in values)
        settings.api = text(*value, "openai.api", path);
    if (auto value = "timeout" in values)
        settings.timeout = positiveNumber(*value, "openai.timeout", path);
    return settings;
}

private MapSettings readMap(JSONValue section, string path) @safe
{
    MapSettings settings;
    if (section.type != JSONType.object)
        fail("E_CONFIG", "'map' in " ~ path ~ " must be an object");
    auto values = section.objectNoRef;
    if (auto value = "summary" in values)
        settings.summary = boolOr(*value, true);
    if (auto value = "max_entries" in values)
        settings.maxEntries = positiveNumber(*value, "map.max_entries", path);
    return settings;
}

private string text(JSONValue value, string field, string path) @safe
{
    if (value.type != JSONType.string)
        fail("E_CONFIG", field ~ " in " ~ path ~ " must be a string");
    return value.str;
}

private uint positiveNumber(JSONValue value, string field, string path) @safe
{
    if (value.type != JSONType.integer && value.type != JSONType.uinteger)
        fail("E_CONFIG", field ~ " in " ~ path ~ " must be a positive integer");
    if (value.integer <= 0)
        fail("E_CONFIG", field ~ " in " ~ path ~ " must be positive");
    return cast(uint) value.integer;
}

private string[string] readStringTable(JSONValue section, string path) @safe
{
    if (section.type != JSONType.object)
        fail("E_CONFIG", "expected an object of string values in " ~ path);
    string[string] table;
    foreach (key, value; section.objectNoRef)
    {
        if (value.type != JSONType.string)
            fail("E_CONFIG", key ~ " in " ~ path ~ " must be a string");
        table[key] = value.str;
    }
    return table;
}

/// Resolve one setting from, in order: an explicit flag, the environment, the
/// configuration file, then the built-in default.
///
/// Environment names are listed most-specific first so an application-specific
/// name can override a general one.
string resolveSetting(string flag, string[] environmentNames, string configured,
        string fallback) @safe
{
    if (flag.length)
        return flag;
    foreach (name; environmentNames)
    {
        auto value = environment.get(name, "");
        if (value.length)
            return value;
    }
    if (configured.length)
        return configured;
    return fallback;
}

/// Resolve a numeric setting, ignoring unparsable or non-positive values so a
/// stray environment variable cannot silently disable a deadline.
uint resolveTimeout(string flag, string[] environmentNames, uint configured) @safe
{
    if (flag.length)
    {
        auto parsed = parsePositive(flag);
        if (parsed)
            return parsed;
    }
    foreach (name; environmentNames)
    {
        auto parsed = parsePositive(environment.get(name, ""));
        if (parsed)
            return parsed;
    }
    return configured;
}

private uint parsePositive(string value) @safe
{
    try
    {
        auto parsed = value.strip.to!uint;
        return parsed ? parsed : 0;
    }
    catch (Exception)
    {
        return 0;
    }
}

/// Resolve a boolean setting from an explicit flag or an environment variable.
bool resolveFlag(string flag, string[] environmentNames, bool fallback) @safe
{
    if (flag.length)
        return isTrue(flag);
    foreach (name; environmentNames)
    {
        auto value = environment.get(name, "");
        if (isTrue(value))
            return true;
        if (isFalse(value))
            return false;
    }
    return fallback;
}

private bool isTrue(string value) @safe
{
    return equalsAny(value, ["1", "true", "yes", "on"]);
}

private bool isFalse(string value) @safe
{
    return equalsAny(value, ["0", "false", "no", "off"]);
}

private bool equalsAny(string value, string[] options) @safe
{
    foreach (option; options)
        if (equalsIgnoreCase(value, option))
            return true;
    return false;
}

/// ASCII case-insensitive comparison without allocating.
private bool equalsIgnoreCase(string value, string other) @safe
{
    if (value.length != other.length)
        return false;
    foreach (i, c; value)
    {
        auto left = cast(char) c;
        auto right = cast(char) other[i];
        if (left >= 'A' && left <= 'Z')
            left = cast(char) (left + 32);
        if (right >= 'A' && right <= 'Z')
            right = cast(char) (right + 32);
        if (left != right)
            return false;
    }
    return true;
}

import std.string : strip;