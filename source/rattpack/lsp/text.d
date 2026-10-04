module rattpack.lsp.text;

import std.exception : enforce;
import std.json : JSONValue;
import std.path : absolutePath, buildNormalizedPath, dirSeparator, isAbsolute;
import std.string : indexOf, startsWith, replace;
import std.uri : decodeComponent, encodeComponent;
import std.utf : decode;

/// LSP positions count UTF-16 code units, while lexer columns count UTF-8 bytes.
struct Position
{
    size_t line;
    size_t character;

    JSONValue toJSON() const @safe
    {
        return JSONValue([
            "line": JSONValue(line),
            "character": JSONValue(character)
        ]);
    }
}

private size_t nextLine(string text, size_t start) @safe
{
    auto end = start;
    while (end < text.length && text[end] != '\n' && text[end] != '\r')
        end++;
    if (end < text.length && text[end++] == '\r' && end < text.length && text[end] == '\n')
        end++;
    return end;
}

size_t lineStart(string text, size_t line) @safe
{
    size_t start;
    foreach (_; 0 .. line)
    {
        if (start == text.length)
            return start;
        start = nextLine(text, start);
    }
    return start;
}

size_t offsetAt(string text, Position position) @safe
{
    auto offset = lineStart(text, position.line);
    size_t units;
    while (offset < text.length && text[offset] != '\n' && text[offset] != '\r')
    {
        if (units >= position.character)
            break;
        auto next = offset;
        auto character = decode(text, next);
        auto width = character > 0xffff ? 2 : 1;
        enforce(units + width <= position.character, "position splits a UTF-16 surrogate pair");
        units += width;
        offset = next;
    }
    return offset;
}

Position positionAt(string text, size_t offset) @safe
{
    enforce(offset <= text.length, "offset exceeds document length");
    Position result;
    size_t start;
    while (start < offset)
    {
        auto end = nextLine(text, start);
        if (end > offset || (end == text.length && text[end - 1] != '\n' && text[end - 1] != '\r'))
            break;
        start = end;
        result.line++;
    }
    for (auto index = start; index < offset;)
    {
        if (text[index] == '\r' || text[index] == '\n')
            break;
        auto character = decode(text, index);
        result.character += character > 0xffff ? 2 : 1;
    }
    return result;
}

JSONValue textRange(string text, size_t start, size_t end) @safe
{
    return JSONValue([
        "start": positionAt(text, start).toJSON,
        "end": positionAt(text, end).toJSON
    ]);
}

string applyEdit(string text, Position start, Position end, string replacement) @safe
{
    enforce(end.line > start.line || (end.line == start.line
            && end.character >= start.character), "reversed edit range");
    auto first = offsetAt(text, start), last = offsetAt(text, end);
    return text[0 .. first] ~ replacement ~ text[last .. $];
}

/// Empty for non-file schemes (for example an unsaved untitled: buffer).
string pathFromURI(string uri) @safe
{
    if (!uri.startsWith("file://"))
        return "";
    auto rest = uri[7 .. $];
    auto slash = rest.indexOf('/');
    enforce(slash >= 0, "file URI requires an absolute path");
    auto host = rest[0 .. cast(size_t) slash];
    auto path = decodeComponent(rest[cast(size_t) slash .. $]);
    if (host.length && host != "localhost")
        path = "//" ~ decodeComponent(host) ~ path;
    // Native path normalization handles drive-letter and UNC paths on Win32.
    if (path.length >= 3 && path[0] == '/' && path[2] == ':' && isAbsolute(path[1 .. $]))
        path = path[1 .. $];
    return buildNormalizedPath(absolutePath(path));
}

string uriFromPath(string path) @safe
{
    auto normalized = buildNormalizedPath(absolutePath(path)).replace(dirSeparator, "/");
    auto encoded = encodeComponent(normalized).replace("%2F", "/").replace("%3A", ":");
    if (encoded.startsWith("//"))
        return "file:" ~ encoded;
    return "file://" ~ (encoded.startsWith("/") ? "" : "/") ~ encoded;
}
