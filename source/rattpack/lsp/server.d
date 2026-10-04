module rattpack.lsp.server;

import rattpack.diagnostic : Diagnostic, Location;
import rattpack.lsp.analysis;
import rattpack.lsp.catalog;
import rattpack.lsp.text;
import rattpack.script.lexer : TokenKind;
import std.algorithm : canFind, sort;
import std.exception : enforce;
import std.file : exists, isFile, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, dirName;
import std.stdio : File;
import std.string : endsWith, indexOf, splitLines, startsWith, strip, toLower;
import std.conv : to;
import std.utf : validate;

private enum RpcError
{
    parse = -32_700,
    invalidRequest = -32_600,
    methodNotFound = -32_601,
    invalidParams = -32_602,
    internal = -32_603,
    notInitialized = -32_002
}

private class ProtocolError : Exception
{
    int code;
    this(int code, string message) @safe
    {
        this.code = code;
        super(message);
    }
}

private JSONValue field(JSONValue object, string key) @safe
{
    if (object.type != JSONType.object || key !in object.objectNoRef)
        throw new ProtocolError(RpcError.invalidParams, "missing field: " ~ key);
    return object[key];
}

private string stringValue(JSONValue value) @safe
{
    if (value.type != JSONType.string)
        throw new ProtocolError(RpcError.invalidParams, "expected string");
    return value.str;
}

private long integerValue(JSONValue value) @safe
{
    if (value.type != JSONType.integer)
        throw new ProtocolError(RpcError.invalidParams, "expected signed integer");
    return value.integer;
}

private Position positionValue(JSONValue value) @safe
{
    auto line = integerValue(field(value, "line"));
    auto character = integerValue(field(value, "character"));
    if (line < 0 || character < 0)
        throw new ProtocolError(RpcError.invalidParams, "negative document position");
    return Position(cast(size_t) line, cast(size_t) character);
}

JSONValue errorResponse(JSONValue id, int code, string message) @safe
{
    return JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "id": id,
        "error": JSONValue([
            "code": JSONValue(code),
            "message": JSONValue(message)
        ])
    ]);
}

private JSONValue notification(string method, JSONValue params) @safe
{
    return JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "method": JSONValue(method),
        "params": params
    ]);
}

private JSONValue location(Document document, size_t start, size_t end) @safe
{
    return JSONValue([
        "uri": JSONValue(document.uri),
        "range": textRange(document.text, start, end)
    ]);
}

private JSONValue diagnosticJSON(Document document, Diagnostic diagnostic) @safe
{
    auto start = document.byteOffset(diagnostic.location);
    // Lexer locations are byte columns. Highlight a token, or a zero-width EOF.
    auto end = start;
    if (end < document.text.length && document.text[end] != '\n' && document.text[end] != '\r')
    {
        import std.utf : decode;

        decode(document.text, end);
    }
    foreach (index, token; document.tokens)
        if (document.offsets[index] == start && token.kind == TokenKind.identifier)
            end = start + token.text.length;
    auto prefix = diagnostic.location.toString ~ ": " ~ diagnostic.code ~ ": ";
    auto message = diagnostic.msg.startsWith(prefix)
        ? diagnostic.msg[prefix.length .. $] : diagnostic.msg;
    return JSONValue([
        "range": textRange(document.text, start, end),
        "severity": JSONValue(1),
        "code": JSONValue(diagnostic.code),
        "source": JSONValue("rattpack"),
        "message": JSONValue(message)
    ]);
}

/// One synchronous LSP session. All analysis is static; no evaluator is installed.
class Session
{
    private Catalog catalog;
    private Document[string] documents;
    private bool initialized;
    private bool shutdown;
    bool exited;
    int exitCode = 1;

    this() @safe
    {
        catalog = new Catalog;
    }

    private Document document(JSONValue params)
    {
        auto uri = stringValue(field(field(params, "textDocument"), "uri"));
        if (auto open = uri in documents)
            return *open;
        auto path = pathFromURI(uri);
        if (!path.length || !exists(path) || !isFile(path))
            throw new ProtocolError(RpcError.invalidParams, "document is not open or readable");
        return new Document(uri, readText(path));
    }

    private Document imported(Document from, Binding binding)
    {
        if (!binding.moduleName.canFind('/') && !binding.moduleName.canFind('\\'))
            return null;
        if (!from.path.length)
            return null;
        auto path = buildNormalizedPath(absolutePath(binding.moduleName, dirName(from.path)));
        foreach (open; documents.byValue)
            if (open.path == path)
                return open;
        if (!exists(path) || !isFile(path))
            return null;
        return new Document(uriFromPath(path), readText(path));
    }

    private JSONValue[] diagnostics(Document document)
    {
        bool[string] loading, checked;
        JSONValue[] check(Document current)
        {
            auto key = current.path.length ? current.path : current.uri;
            loading[key] = true;
            scope (exit)
                loading.remove(key);
            if (current.diagnostic !is null)
                return [diagnosticJSON(current, current.diagnostic)];
            foreach (binding; current.imports)
            {
                string message;
                if (!binding.moduleName.canFind('/') && !binding.moduleName.canFind('\\'))
                {
                    if (!catalog.hasModule(binding.moduleName))
                        message = "unknown standard module '" ~ binding.moduleName ~ "'";
                    else
                        continue;
                }
                else if ([
                    "Rattspec", "Rattspec.m", "Rattspec.in", "Rattspec.m.in"
                ].canFind(baseName(binding.moduleName)))
                    message = "spec discovery is automatic; do not import specs";
                else
                {
                    auto child = imported(current, binding);
                    if (child is null)
                        message = "module not found: " ~ binding.moduleName;
                    else if (loading.get(child.path, false))
                        message = "cyclic module import: " ~ binding.moduleName;
                    else if (!checked.get(child.path, false))
                    {
                        auto errors = check(child);
                        if (errors.length)
                        {
                            auto error = errors[0];
                            auto related = JSONValue([
                                "location": JSONValue([
                                    "uri": JSONValue(child.uri),
                                    "range": error["range"]
                                ]),
                                "message": error["message"]
                            ]);
                            error.object["range"] = textRange(current.text,
                                    binding.importStart, binding.importEnd);
                            error.object["message"] = JSONValue(
                                    "in imported module " ~ binding.moduleName
                                    ~ ": " ~ error["message"].str);
                            error.object["relatedInformation"] = JSONValue([
                                related
                            ]);
                            return [error];
                        }
                        checked[child.path] = true;
                    }
                }
                if (message.length)
                    return [
                    JSONValue([
                        "range": textRange(current.text, binding.importStart, binding.importEnd),
                        "severity": JSONValue(1),
                        "code": JSONValue("E_IMPORT"),
                        "source": JSONValue("rattpack"),
                        "message": JSONValue(message)
                    ])
                ];
            }
            return null;
        }

        return check(document);
    }

    private void publish(scope void delegate(JSONValue) send)
    {
        foreach (uri; documents.keys.sort)
        {
            auto document = documents[uri];
            auto errors = diagnostics(document);
            send(notification("textDocument/publishDiagnostics", JSONValue([
                "uri": JSONValue(uri),
                "version": JSONValue(document.version_),
                "diagnostics": JSONValue(errors)
            ])));
        }
    }

    private Suggestion[] members(Document document, string receiver, size_t offset)
    {
        auto binding = document.scope_.at(offset).resolve(receiver, offset);
        if (binding is null || !binding.moduleName.length)
            return null;
        if (auto methods = binding.moduleName in catalog.modules)
            return *methods;
        auto child = imported(document, binding);
        if (child is null)
            return null;
        Suggestion[] result;
        foreach (member; child.scope_.bindings)
            result ~= suggestion(member);
        return result;
    }

    private static Suggestion suggestion(Binding binding) @safe
    {
        return Suggestion(binding.name, binding.detail, "", binding.kind == 12
                ? 3 : binding.kind == 2 ? 9 : 6);
    }

    private JSONValue complete(Document document, size_t offset)
    {
        auto word = wordAt(document.text, offset, true);
        Suggestion[] candidates;
        // A partially typed import string may not tokenize yet.
        auto beginning = lineStart(document.text, positionAt(document.text, offset).line);
        auto line = document.text[beginning .. offset].strip;
        bool importContext = line.startsWith("import \"") || line.startsWith("import '");
        if (importContext)
        {
            auto quote = line[7];
            if (line[8 .. $].canFind(quote))
                importContext = false;
            else
            {
                auto prefixLength = line[8 .. $].length;
                word.start = offset - prefixLength;
                word.name = document.text[word.start .. offset];
                foreach (name; moduleNames)
                    candidates ~= Suggestion(name, "import \"" ~ name ~ "\"",
                            "Embedded standard module.", 9);
            }
        }
        if (!importContext)
        {
            if (!codeAt(document.source, offset))
                return JSONValue(cast(JSONValue[]) null);
            if (word.receiver.length)
                candidates = members(document, word.receiver, offset);
            else
            {
                bool[string] seen;
                for (auto scope_ = document.scope_.at(offset); scope_ !is null; scope_ = scope_
                        .parent)
                    foreach_reverse (binding; scope_.bindings)
                        if ((binding.start <= offset || binding.kind == 12)
                                && !seen.get(binding.name, false))
                        {
                            candidates ~= suggestion(binding);
                            seen[binding.name] = true;
                        }
                foreach (item; catalog.builtins)
                    if (!seen.get(item.name, false))
                    {
                        candidates ~= item;
                        seen[item.name] = true;
                    }
                foreach (name; keywords ~ annotations ~ [
                    "monorepo", "member", "vendored", "ignore", "deps", "dep",
                    "registry"
                ])
                    if (!seen.get(name, false))
                    {
                        candidates ~= Suggestion(name, name,
                                "Rattscript language/host keyword.", 14);
                        seen[name] = true;
                    }
            }
        }
        JSONValue[] result;
        bool[string] included;
        candidates.sort!((left, right) => left.name < right.name);
        foreach (item; candidates)
            if (item.name.startsWith(word.name) && !included.get(item.name, false))
            {
                included[item.name] = true;
                result ~= JSONValue([
                    "label": JSONValue(item.name),
                    "kind": JSONValue(item.kind),
                    "detail": JSONValue(item.detail),
                    "documentation": JSONValue([
                        "kind": JSONValue("markdown"),
                        "value": JSONValue(item.documentation)
                    ]),
                    "textEdit": JSONValue([
                        "range": textRange(document.text, word.start,
                                word.end),
                        "newText": JSONValue(item.name)
                    ])
                ]);
            }
        return JSONValue(result);
    }

    private JSONValue hover(Document document, size_t offset)
    {
        if (!codeAt(document.source, offset))
            return JSONValue.init;
        auto word = wordAt(document.text, offset);
        Suggestion[] candidates;
        if (word.receiver.length)
            candidates = members(document, word.receiver, offset);
        else
        {
            auto binding = document.scope_.at(offset).resolve(word.name, offset);
            if (binding !is null)
                candidates = [suggestion(binding)];
            else
                candidates = catalog.builtins;
        }
        foreach (item; candidates)
            if (item.name == word.name)
                return JSONValue([
                "contents": JSONValue([
                    "kind": JSONValue("markdown"),
                    "value": JSONValue("```ratt\n" ~ item.detail ~ "\n```\n" ~ item.documentation)
                ]),
                "range": textRange(document.text, word.start, word.end)
        ]);
        return JSONValue.init;
    }

    private JSONValue definition(Document document, size_t offset)
    {
        foreach (binding; document.imports)
            if (offset >= binding.importStart && offset < binding.importEnd)
            {
                auto child = imported(document, binding);
                return child is null ? JSONValue(cast(JSONValue[]) null) : JSONValue([
                    location(child, 0, 0)
                ]);
            }
        if (!codeAt(document.source, offset))
            return JSONValue(cast(JSONValue[]) null);
        auto word = wordAt(document.text, offset);
        auto binding = document.scope_.at(offset).resolve(word.receiver.length
                ? word.receiver : word.name, offset);
        auto owner = document;
        if (binding !is null && word.receiver.length)
        {
            owner = imported(document, binding);
            binding = owner is null ? null : owner.scope_.resolve(word.name, owner.text.length);
        }
        return binding is null ? JSONValue(cast(JSONValue[]) null) : JSONValue(
                [location(owner, binding.start, binding.end)]);
    }

    private void notify(string method, JSONValue params, scope void delegate(JSONValue) send)
    {
        switch (method)
        {
        case "textDocument/didOpen":
            auto value = field(params, "textDocument");
            auto uri = stringValue(field(value, "uri"));
            auto text = stringValue(field(value, "text"));
            validate(text);
            documents[uri] = new Document(uri, text, stringValue(field(value,
                    "languageId")), integerValue(field(value, "version")));
            publish(send);
            break;
        case "textDocument/didChange":
            auto value = field(params, "textDocument");
            auto uri = stringValue(field(value, "uri"));
            if (uri !in documents)
                throw new ProtocolError(RpcError.invalidParams, "changed document is not open");
            auto current = documents[uri];
            auto version_ = integerValue(field(value, "version"));
            if (version_ <= current.version_)
                break;
            auto changes = field(params, "contentChanges");
            if (changes.type != JSONType.array)
                throw new ProtocolError(RpcError.invalidParams, "contentChanges must be an array");
            auto text = current.text;
            foreach (change; changes.array)
            {
                auto replacement = stringValue(field(change, "text"));
                if (change.type == JSONType.object && "range" in change.object)
                {
                    auto range = change["range"];
                    try
                        text = applyEdit(text, positionValue(field(range, "start")),
                                positionValue(field(range, "end")), replacement);
                    catch (Exception error)
                        throw new ProtocolError(RpcError.invalidParams, error.msg);
                }
                else
                    text = replacement;
            }
            validate(text);
            documents[uri] = new Document(uri, text, current.languageId, version_);
            publish(send);
            break;
        case "textDocument/didClose":
            auto uri = stringValue(field(field(params, "textDocument"), "uri"));
            documents.remove(uri);
            send(notification("textDocument/publishDiagnostics", JSONValue([
                "uri": JSONValue(uri),
                "diagnostics": JSONValue(cast(JSONValue[]) null)
            ])));
            publish(send);
            break;
        case "textDocument/didSave":
        case "workspace/didChangeWatchedFiles":
            publish(send);
            break;
        default:
            break;
        }
    }

    void handle(JSONValue message, scope void delegate(JSONValue) send)
    {
        JSONValue id;
        bool request;
        try
        {
            if (message.type != JSONType.object || "method" !in message.object
                    || "jsonrpc" !in message.object || message["jsonrpc"] != JSONValue("2.0")
                    || message["method"].type != JSONType.string)
                throw new ProtocolError(RpcError.invalidRequest, "invalid JSON-RPC request");
            request = ("id" in message.object) !is null;
            if (request)
            {
                id = message["id"];
                if (id.type != JSONType.integer && id.type != JSONType.uinteger
                        && id.type != JSONType.string && id.type != JSONType.null_)
                {
                    id = JSONValue.init;
                    throw new ProtocolError(RpcError.invalidRequest, "invalid request id");
                }
            }
            auto method = message["method"].str;
            auto params = "params" in message.object ? message["params"] : JSONValue.init;
            if (method == "exit")
            {
                exited = true;
                exitCode = shutdown ? 0 : 1;
                return;
            }
            JSONValue result;
            if (method == "initialize" && request)
            {
                if (initialized)
                    throw new ProtocolError(RpcError.invalidRequest, "already initialized");
                initialized = true;
                result = JSONValue([
                    "capabilities": JSONValue([
                        "positionEncoding": JSONValue("utf-16"),
                        "textDocumentSync": JSONValue([
                            "openClose": JSONValue(true),
                            "change": JSONValue(2),
                            "save": JSONValue(["includeText": JSONValue(false)])
                        ]),
                        "completionProvider": JSONValue([
                            "triggerCharacters": JSONValue([
                                JSONValue("."), JSONValue("\""), JSONValue("'")
                            ])
                        ]),
                        "hoverProvider": JSONValue(true),
                        "definitionProvider": JSONValue(true),
                        "documentSymbolProvider": JSONValue(true)
                    ]),
                    "serverInfo": JSONValue([
                        "name": JSONValue("ratt-language-server"),
                        "version": JSONValue("0.1.0")
                    ])
                ]);
            }
            else
            {
                if (!initialized)
                    throw new ProtocolError(RpcError.notInitialized, "server is not initialized");
                if (shutdown)
                    throw new ProtocolError(RpcError.invalidRequest, "server is shutting down");
                if (!request)
                {
                    notify(method, params, send);
                    return;
                }
                if (method == "shutdown")
                    shutdown = true;
                else if ([
                    "textDocument/completion", "textDocument/hover",
                    "textDocument/definition", "textDocument/documentSymbol"
                ].canFind(method))
                {
                    auto current = document(params);
                    if (method == "textDocument/documentSymbol")
                    {
                        JSONValue[] symbols;
                        foreach (binding; current.bindings)
                            symbols ~= JSONValue([
                            "name": JSONValue(binding.name),
                            "kind": JSONValue(binding.kind),
                            "location": location(current, binding.start, binding.end)
                        ]);
                        result = JSONValue(symbols);
                    }
                    else
                    {
                        auto offset = offsetAt(current.text,
                                positionValue(field(params, "position")));
                        if (method == "textDocument/completion")
                            result = complete(current, offset);
                        else if (method == "textDocument/hover")
                            result = hover(current, offset);
                        else
                            result = definition(current, offset);
                    }
                }
                else
                    throw new ProtocolError(RpcError.methodNotFound, "method not found: " ~ method);
            }
            send(JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "id": id,
                "result": result
            ]));
        }
        catch (ProtocolError error)
        {
            if (request || error.code == RpcError.invalidRequest)
                send(errorResponse(id, error.code, error.msg));
            else
                send(notification("window/logMessage",
                        JSONValue([
                            "type": JSONValue(1),
                            "message": JSONValue(error.msg)
            ])));
        }
        catch (Exception error)
        {
            if (request)
                send(errorResponse(id, RpcError.internal, error.msg));
            else
                send(notification("window/logMessage",
                        JSONValue([
                            "type": JSONValue(1),
                            "message": JSONValue(error.msg)
            ])));
        }
    }
}

/// Read byte-counted LSP framing, including short reads and arbitrary pipe chunks.
bool readMessage(File input, out string body)
{
    char[1] byte_;
    string headers;
    while (!headers.endsWith("\r\n\r\n") && !headers.endsWith("\n\n"))
    {
        if (!input.rawRead(byte_[]).length)
        {
            enforce(!headers.length, "truncated LSP header");
            return false;
        }
        headers ~= byte_[0];
        enforce(headers.length <= 16_384, "LSP header is too large");
    }
    size_t length;
    bool found;
    foreach (header; headers.splitLines)
    {
        auto colon = header.indexOf(':');
        if (colon < 0)
            continue;
        if (header[0 .. cast(size_t) colon].strip.toLower != "content-length")
            continue;
        enforce(!found, "duplicate Content-Length");
        auto value = header[cast(size_t) colon + 1 .. $].strip;
        enforce(value.length && value[0] != '-' && value[0] != '+', "invalid Content-Length");
        length = value.to!size_t;
        enforce(length <= 16 * 1024 * 1024, "LSP message exceeds 16 MiB");
        found = true;
    }
    enforce(found, "missing Content-Length");
    auto bytes = new char[length];
    size_t offset;
    while (offset < length)
    {
        auto count = input.rawRead(bytes[offset .. $]).length;
        enforce(count, "truncated LSP body");
        offset += count;
    }
    body = bytes.idup;
    return true;
}

void writeMessage(File output, JSONValue message)
{
    auto body = message.toString;
    auto framed = "Content-Length: " ~ body.length.to!string ~ "\r\n\r\n" ~ body;
    output.rawWrite(framed);
    output.flush;
}

int serve(File input, File output, File errors)
{
    auto session = new Session;
    void send(JSONValue message)
    {
        writeMessage(output, message);
    }

    try
    {
        string body;
        while (!session.exited && readMessage(input, body))
        {
            JSONValue message;
            try
                message = parseJSON(body);
            catch (Exception)
            {
                send(errorResponse(JSONValue.init, RpcError.parse, "invalid JSON"));
                continue;
            }
            session.handle(message, &send);
        }
        return session.exitCode;
    }
    catch (Exception error)
    {
        errors.writeln("ratt-language-server: " ~ error.msg);
        return 1;
    }
}
