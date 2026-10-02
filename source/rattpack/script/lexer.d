module rattpack.script.lexer;

import rattpack.diagnostic;
import std.ascii;
import std.conv : to;

enum TokenKind
{
    eof,
    newline,
    identifier,
    number,
    string_,
    symbol
}

struct Token
{
    TokenKind kind;
    string text;
    Location location;
}

class Lexer
{
    private string source;
    private string file;
    private size_t index;
    private size_t line = 1;
    private size_t column = 1;

    this(string source, string file = "<input>") @safe
    {
        this.source = source;
        this.file = file;
    }

    private char take() @safe
    {
        auto c = source[index++];
        if (c == '\n')
        {
            line++;
            column = 1;
        }
        else
            column++;
        return c;
    }

    Token[] tokenize() @safe
    {
        Token[] result;
        while (index < source.length)
        {
            char c = source[index];
            if (c == ' ' || c == '\t' || c == '\r')
            {
                take;
                continue;
            }
            if (c == '#' || (c == '/' && index + 1 < source.length && source[index + 1] == '/'))
            {
                while (index < source.length && source[index] != '\n')
                    take;
                continue;
            }
            auto location = Location(file, line, column);
            if (c == '\n')
            {
                take;
                result ~= Token(TokenKind.newline, "\n", location);
                continue;
            }
            auto start = index;
            if (isAlpha(c) || c == '_')
            {
                take;
                while (index < source.length && (isAlphaNum(source[index]) || source[index] == '_'))
                    take;
                result ~= Token(TokenKind.identifier, source[start .. index], location);
            }
            else if (isDigit(c))
            {
                take;
                while (index < source.length && isDigit(source[index]))
                    take;
                if (index + 1 < source.length && source[index] == '.' && isDigit(source[index + 1]))
                {
                    take;
                    while (index < source.length && isDigit(source[index]))
                        take;
                }
                if (index < source.length && (source[index] == 'e' || source[index] == 'E'))
                {
                    take;
                    if (index < source.length && (source[index] == '+' || source[index] == '-'))
                        take;
                    while (index < source.length && isDigit(source[index]))
                        take;
                }
                result ~= Token(TokenKind.number, source[start .. index], location);
            }
            else if (c == '"' || c == '\'')
            {
                auto quote = take;
                string value;
                while (index < source.length && source[index] != quote)
                {
                    c = take;
                    if (c == '\\')
                    {
                        if (index == source.length)
                            fail("E_PARSE", "unfinished escape", location);
                        c = take;
                        switch (c)
                        {
                        case 'n':
                            value ~= '\n';
                            break;
                        case 'r':
                            value ~= '\r';
                            break;
                        case 't':
                            value ~= '\t';
                            break;
                        case 'b':
                            value ~= '\b';
                            break;
                        case 'f':
                            value ~= '\f';
                            break;
                        case '/':
                            value ~= '/';
                            break;
                        case 'u':
                            uint codepoint;
                            foreach (_; 0 .. 4)
                            {
                                if (index == source.length)
                                    fail("E_PARSE", "unfinished unicode escape", location);
                                auto digit = take;
                                if (!isHexDigit(digit))
                                    fail("E_PARSE", "invalid unicode escape", location);
                                codepoint = codepoint * 16 + (isDigit(digit)
                                        ? digit - '0' : toLower(digit) - 'a' + 10);
                            }
                            if (codepoint >= 0xD800 && codepoint <= 0xDFFF)
                                fail("E_PARSE",
                                        "surrogate unicode escapes are unsupported; use UTF-8",
                                        location);
                            value ~= (cast(dchar) codepoint).to!string;
                            break;
                        case '\\':
                            value ~= '\\';
                            break;
                        case '"':
                            value ~= '"';
                            break;
                        case '\'':
                            value ~= '\'';
                            break;
                        default:
                            fail("E_PARSE", "unknown escape", location);
                        }
                    }
                    else
                        value ~= c;
                }
                if (index == source.length)
                    fail("E_PARSE", "unterminated string", location);
                take;
                result ~= Token(TokenKind.string_, value, location);
            }
            else
            {
                take;
                if (index < source.length)
                {
                    auto pair = source[start .. index + 1];
                    if (pair == "==" || pair == "!=" || pair == "<=" || pair == ">="
                            || pair == "&&" || pair == "||" || pair == "+=" || pair == "-="
                            || pair == "*=" || pair == "/=" || pair == "->" || pair == "..")
                        take;
                }
                auto symbol = source[start .. index];
                if (symbol.length == 1 && !isPunctuation(c))
                    fail("E_PARSE", "invalid character", location);
                result ~= Token(TokenKind.symbol, symbol, location);
            }
        }
        result ~= Token(TokenKind.eof, "", Location(file, line, column));
        return result;
    }
}
