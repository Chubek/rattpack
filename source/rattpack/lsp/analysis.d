module rattpack.lsp.analysis;

import rattpack.diagnostic : Diagnostic, Location, fail;
import rattpack.lsp.catalog : signature;
import rattpack.lsp.text;
import rattpack.script.ast;
import rattpack.script.lexer;
import rattpack.script.lint : lint;
import rattpack.script.parser : Parser;
import std.algorithm : canFind, min;
import std.ascii : isAlphaNum;
import std.path : baseName, stripExtension;
import std.string : endsWith, startsWith, strip, stripLeft;

class Binding
{
    string name;
    string detail;
    string moduleName;
    int kind = 13; // LSP SymbolKind.Variable
    size_t start;
    size_t end;
    size_t importStart;
    size_t importEnd;
}

class Scope
{
    Scope parent;
    size_t start;
    size_t end;
    Binding[] bindings;
    Scope[] children;

    this(Scope parent, size_t start, size_t end) @safe
    {
        this.parent = parent;
        this.start = start;
        this.end = end;
    }

    Scope at(size_t offset) @safe
    {
        foreach (child; children)
            if (offset >= child.start && offset < child.end)
                return child.at(offset);
        return this;
    }

    Binding resolve(string name, size_t offset) @safe
    {
        foreach_reverse (binding; bindings)
            if (binding.name == name && (binding.start <= offset || binding.kind == 12))
                return binding;
        return parent is null ? null : parent.resolve(name, offset);
    }
}

private bool identifier(char character) @safe
{
    return isAlphaNum(character) || character == '_';
}

struct Word
{
    string name;
    string receiver;
    size_t start;
    size_t end;
}

Word wordAt(string text, size_t offset, bool complete = false) @safe
{
    Word result;
    result.start = result.end = offset;
    while (result.start && identifier(text[result.start - 1]))
        result.start--;
    while (result.end < text.length && identifier(text[result.end]))
        result.end++;
    result.name = text[result.start .. (complete ? offset : result.end)];
    auto dot = result.start;
    while (dot && (text[dot - 1] == ' ' || text[dot - 1] == '\t'))
        dot--;
    if (dot && text[dot - 1] == '.')
    {
        auto end = dot - 1;
        while (end && (text[end - 1] == ' ' || text[end - 1] == '\t'))
            end--;
        auto start = end;
        while (start && identifier(text[start - 1]))
            start--;
        result.receiver = text[start .. end];
    }
    return result;
}

bool codeAt(string text, size_t offset) @safe
{
    char quote = 0;
    bool comment;
    for (size_t index; index < offset; index++)
    {
        auto character = text[index];
        if (comment)
        {
            if (character == '\n' || character == '\r')
                comment = false;
        }
        else if (quote)
        {
            if (character == '\\')
                index++;
            else if (character == quote)
                quote = 0;
        }
        else if (character == '\'' || character == '"')
            quote = character;
        else if (character == '#' || (character == '/' && index + 1 < offset && text[index + 1] == '/'))
            comment = true;
    }
    return !quote && !comment;
}

/// Mask template directives/substitutions while preserving every byte offset.
/// Template expressions are never evaluated by an editor service.
string staticSource(string text, string file, bool template_) @safe
{
    auto source = text.dup;
    char quote = 0;
    bool comment;
    for (size_t index; index < text.length;)
    {
        if (text[index] == '\r' && (index + 1 == text.length || text[index + 1] != '\n'))
            source[index] = '\n';
        if (template_ && !quote && !comment && text[index] == '@')
        {
            auto start = index;
            while (start && text[start - 1] != '\n' && text[start - 1] != '\r')
                start--;
            if (!text[start .. index].stripLeft.length)
            {
                auto end = index;
                while (end < text.length && text[end] != '\n' && text[end] != '\r')
                    end++;
                auto directive = text[index .. end].strip;
                if (directive.startsWith("@if ") || directive.startsWith("@foreach ")
                        || directive == "@else" || directive == "@end")
                {
                    source[index .. end] = ' ';
                    index = end;
                    continue;
                }
            }
        }
        if (template_ && !comment && index + 1 < text.length && text[index .. index + 2] == "@{")
        {
            size_t end = index + 2, depth = 1;
            char innerQuote = 0;
            while (end < text.length && depth)
            {
                auto character = text[end++];
                if (innerQuote)
                {
                    if (character == '\\' && end < text.length)
                        end++;
                    else if (character == innerQuote)
                        innerQuote = 0;
                }
                else if (character == '\'' || character == '"')
                    innerQuote = character;
                else if (character == '{')
                    depth++;
                else if (character == '}')
                    depth--;
            }
            if (depth)
            {
                auto position = positionAt(text, index);
                auto byteColumn = index - lineStart(text, position.line) + 1;
                fail("E_TEMPLATE", "unterminated substitution", Location(file,
                        position.line + 1, byteColumn));
            }
            foreach (offset; index .. end)
                if (text[offset] != '\r' && text[offset] != '\n')
                    source[offset] = ' ';
            if (!quote)
                source[index .. index + 3] = "___";
            index = end;
            continue;
        }
        auto character = text[index++];
        if (comment)
        {
            if (character == '\n' || character == '\r')
                comment = false;
        }
        else if (quote)
        {
            if (character == '\\' && index < text.length)
                index++;
            else if (character == quote)
                quote = 0;
        }
        else if (character == '\'' || character == '"')
            quote = character;
        else if (character == '#' || (character == '/' && index < text.length && text[index] == '/'))
            comment = true;
    }
    return source.idup;
}

final class Document
{
    string uri;
    string path;
    string text;
    string source;
    string languageId;
    long version_;
    Stmt ast;
    Token[] tokens;
    size_t[] offsets;
    Scope scope_;
    Binding[] bindings;
    Binding[] imports;
    Diagnostic diagnostic;

    this(string uri, string text, string languageId = "rattscript", long version_ = 0) @safe
    {
        this.uri = uri;
        this.path = pathFromURI(uri);
        this.text = text;
        this.languageId = languageId;
        this.version_ = version_;
        analyze();
    }

    size_t byteOffset(Location location) const @safe
    {
        auto start = lineStart(text, location.line ? location.line - 1 : 0);
        return min(text.length, start + (location.column ? location.column - 1 : 0));
    }

    private size_t tokenIndex(Location location) const @safe
    {
        auto offset = byteOffset(location);
        foreach (index, start; offsets)
            if (start >= offset)
                return index;
        return tokens.length;
    }

    private size_t tokenEnd(size_t index) const @safe
    {
        auto start = offsets[index];
        if (tokens[index].kind != TokenKind.string_)
            return min(text.length, start + tokens[index].text.length);
        auto end = start + 1;
        while (end < source.length)
        {
            auto character = source[end++];
            if (character == '\\' && end < source.length)
                end++;
            else if (character == source[start])
                break;
        }
        return end;
    }

    private Binding bind(Scope scope_, string name, string detail, int kind, Location location) @safe
    {
        auto binding = new Binding;
        binding.name = name;
        binding.detail = detail;
        binding.kind = kind;
        binding.start = byteOffset(location);
        binding.end = binding.start;
        for (auto index = tokenIndex(location); index < tokens.length; index++)
            if ((tokens[index].kind == TokenKind.identifier
                    && tokens[index].text == name) || (kind == 2
                    && tokens[index].kind == TokenKind.string_))
            {
                binding.start = offsets[index];
                binding.end = tokenEnd(index);
                break;
            }
        scope_.bindings ~= binding;
        bindings ~= binding;
        return binding;
    }

    private void importBinding(Scope scope_, string name, string alias_, Location location) @safe
    {
        auto defaultName = stripExtension(baseName(name.endsWith(".in") ? name[0 .. $ - 3] : name));
        auto binding = bind(scope_, alias_.length ? alias_ : defaultName,
                "import \"" ~ name ~ "\"" ~ (alias_.length ? " as " ~ alias_ : ""),
                alias_.length ? 13 : 2, location);
        binding.kind = 2; // LSP SymbolKind.Module
        binding.moduleName = name;
        for (auto index = tokenIndex(location); index < tokens.length; index++)
            if (tokens[index].kind == TokenKind.string_)
            {
                binding.importStart = offsets[index];
                binding.importEnd = tokenEnd(index);
                break;
            }
        imports ~= binding;
    }

    private Scope childScope(Stmt block, Scope parent) @safe
    {
        auto start = byteOffset(block.location);
        auto end = text.length;
        size_t depth;
        for (auto index = tokenIndex(block.location); index < tokens.length; index++)
        {
            if (tokens[index].kind != TokenKind.symbol)
                continue;
            if (tokens[index].text == "{")
                depth++;
            else if (tokens[index].text == "}" && depth && --depth == 0)
            {
                end = offsets[index] + 1;
                break;
            }
        }
        auto scope_ = new Scope(parent, start, end);
        parent.children ~= scope_;
        return scope_;
    }

    void analyze() @safe
    {
        ast = null;
        diagnostic = null;
        tokens = null;
        offsets = null;
        bindings = null;
        imports = null;
        scope_ = new Scope(null, 0, text.length);
        source = text;
        try
        {
            source = staticSource(text, path.length ? path : uri, (path.length
                    ? path : uri).endsWith(".in"));
            tokens = new Lexer(source, path.length ? path : uri).tokenize;
            foreach (token; tokens)
                offsets ~= byteOffset(token.location);
            ast = new Parser(source, path.length ? path : uri).parse;
        }
        catch (Diagnostic error)
        {
            diagnostic = error;
            // Index complete preceding statements while the current line is being edited.
            auto prefix = lineStart(text, error.location.line ? error.location.line - 1 : 0);
            if (prefix)
                try
                {
                    ast = new Parser(source[0 .. prefix], path.length ? path : uri).parse;
                    if (!tokens.length)
                    {
                        tokens = new Lexer(source[0 .. prefix], path.length ? path : uri).tokenize;
                        foreach (token; tokens)
                            offsets ~= byteOffset(token.location);
                    }
                }
                catch (Diagnostic)
                {
                }
            if (ast is null)
            {
                // Imports remain useful for completion while a member expression is unfinished.
                foreach (index, token; tokens)
                    if (token.kind == TokenKind.identifier && token.text == "import"
                            && index + 1 < tokens.length
                            && tokens[index + 1].kind == TokenKind.string_)
                    {
                        auto alias_ = index + 3 < tokens.length && tokens[index + 2].text == "as"
                            && tokens[index + 3].kind == TokenKind.identifier
                            ? tokens[index + 3].text : "";
                        importBinding(scope_, tokens[index + 1].text, alias_, token.location);
                    }
                return;
            }
        }

        void delegate(Stmt, Scope) @safe visit;
        void parameters(Parameter[] parameters, Scope scope_, Location location) @safe
        {
            auto index = tokenIndex(location);
            while (index < tokens.length && tokens[index].text != "(")
                index++;
            if (index < tokens.length)
            {
                scope_.start = offsets[index];
                index++;
            }
            size_t depth, parameterIndex;
            bool needsName = true;
            while (index < tokens.length && parameterIndex < parameters.length)
            {
                auto token = tokens[index++];
                if (needsName && token.kind == TokenKind.identifier)
                {
                    auto parameter = parameters[parameterIndex++];
                    bind(scope_, parameter.name, parameter.name ~ ": " ~ (parameter.annotation.length
                            ? parameter.annotation : "any"), 13, token.location);
                    needsName = false;
                }
                else if (token.kind == TokenKind.symbol)
                {
                    if (["(", "[", "{"].canFind(token.text))
                        depth++;
                    else if ([")", "]", "}"].canFind(token.text))
                    {
                        if (!depth)
                            break;
                        depth--;
                    }
                    else if (token.text == "," && !depth)
                        needsName = true;
                }
            }
        }

        void visitExpression(Expr expression, Scope scope_) @safe
        {
            if (expression is null)
                return;
            visitExpression(expression.left, scope_);
            visitExpression(expression.right, scope_);
            foreach (entry; expression.entries)
                visitExpression(entry, scope_);
            foreach (parameter; expression.parameters)
                visitExpression(parameter.defaultValue, scope_);
            if (expression.body !is null)
            {
                auto child = childScope(expression.body, scope_);
                parameters(expression.parameters, child, expression.location);
                visit(expression.body, child);
            }
        }

        visit = (Stmt statement, Scope scope_) {
            if (statement is null)
                return;
            if (statement.kind == StmtKind.variable)
            {
                auto type = statement.annotation;
                if (!type.length && statement.expression.kind == ExprKind.literal)
                    type = statement.expression.literal.typeName;
                auto detail = statement.expression.kind == ExprKind.function_ ? signature(statement.name,
                        statement.expression.parameters) : "let " ~ statement.name ~ (type.length
                        ? ": " ~ type : "");
                bind(scope_, statement.name, detail,
                        statement.expression.kind == ExprKind.function_ ? 12 : 13,
                        statement.location);
            }
            else if (statement.kind == StmtKind.function_)
                bind(scope_, statement.name, signature(statement.name,
                        statement.parameters, statement.annotation), 12, statement.location);
            else if (statement.kind == StmtKind.import_)
                importBinding(scope_, statement.name, statement.annotation, statement.location);
            foreach (child; statement.statements)
                visit(child, scope_);
            visitExpression(statement.expression, scope_);
            visitExpression(statement.extra, scope_);
            foreach (parameter; statement.parameters)
                visitExpression(parameter.defaultValue, scope_);
            if (statement.body !is null)
            {
                auto child = statement.kind == StmtKind.section ? scope_
                    : childScope(statement.body, scope_);
                if (statement.kind == StmtKind.function_)
                    parameters(statement.parameters, child, statement.location);
                if (statement.kind == StmtKind.for_)
                    bind(child, statement.name, statement.name ~ ": any", 13, statement.location);
                visit(statement.body, child);
            }
            if (statement.otherwise !is null)
                visit(statement.otherwise, statement.otherwise.kind == StmtKind.if_
                        ? scope_ : childScope(statement.otherwise, scope_));
        };
        visit(ast, scope_);
        try
        {
            lint(ast);
        }
        catch (Diagnostic error)
        {
            if (diagnostic is null)
                diagnostic = error;
        }
    }
}
