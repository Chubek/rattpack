module rattpack.script.parser;

import rattpack.script.ast;
import rattpack.script.lexer;
import rattpack.script.value;
import rattpack.diagnostic;
import std.conv : to;
import std.algorithm : canFind;

class Parser
{
    private Token[] tokens;
    private size_t index;
    this(string source, string file = "<input>") @safe
    {
        tokens = new Lexer(source, file).tokenize;
    }

    private @property Token current() @safe
    {
        return tokens[index];
    }

    private Token take() @safe
    {
        auto t = current;
        if (t.kind != TokenKind.eof)
            index++;
        return t;
    }

    private bool match(string text) @safe
    {
        if ((current.kind == TokenKind.symbol
                || current.kind == TokenKind.identifier) && current.text == text)
        {
            take;
            return true;
        }
        return false;
    }

    private Token expect(string text) @safe
    {
        if (current.kind == TokenKind.string_ || current.text != text)
            fail("E_PARSE", "expected '" ~ text ~ "', got '" ~ current.text ~ "'", current.location);
        return take;
    }

    private Token identifier() @safe
    {
        if (current.kind != TokenKind.identifier)
            fail("E_PARSE", "expected identifier", current.location);
        return take;
    }

    private void newlines() @safe
    {
        while (current.kind == TokenKind.newline)
            take;
    }

    private void separators() @safe
    {
        while (current.kind == TokenKind.newline || current.text == ";")
            take;
    }

    Stmt parse() @safe
    {
        auto block = new Stmt(StmtKind.block, current.location);
        separators;
        while (current.kind != TokenKind.eof)
        {
            block.statements ~= statement;
            separators;
        }
        return block;
    }

    private Stmt block() @safe
    {
        auto result = new Stmt(StmtKind.block, expect("{").location);
        separators;
        while (!match("}"))
        {
            if (current.kind == TokenKind.eof)
                fail("E_PARSE", "unterminated block", result.location);
            result.statements ~= statement;
            separators;
        }
        return result;
    }

    private Parameter[] parameters() @safe
    {
        Parameter[] result;
        expect("(");
        newlines;
        while (!match(")"))
        {
            Parameter p;
            p.name = identifier.text;
            if (match(":"))
                p.annotation = identifier.text;
            if (match("="))
                p.defaultValue = expression;
            foreach (other; result)
                if (other.name == p.name)
                    fail("E_PARSE", "duplicate parameter", current.location);
            result ~= p;
            newlines;
            if (!match(","))
            {
                expect(")");
                break;
            }
            newlines;
        }
        return result;
    }

    private Stmt statement() @safe
    {
        auto location = current.location;
        if (current.kind == TokenKind.symbol && current.text == "{")
            return block;
        if (match("let") || match("var") || match("const"))
        {
            auto s = new Stmt(StmtKind.variable, location);
            s.name = identifier.text;
            if (match(":"))
                s.annotation = identifier.text;
            expect("=");
            newlines;
            s.expression = expression;
            return s;
        }
        if (current.kind == TokenKind.identifier && current.text == "fn"
                && tokens[index + 1].kind == TokenKind.identifier)
        {
            take;
            auto s = new Stmt(StmtKind.function_, location);
            s.name = identifier.text;
            s.parameters = parameters;
            if (match("->"))
                s.annotation = identifier.text;
            newlines;
            s.body = block;
            return s;
        }
        if (match("if"))
        {
            auto s = new Stmt(StmtKind.if_, location);
            s.expression = expression;
            newlines;
            s.body = block;
            newlines;
            if (match("else"))
            {
                newlines;
                s.otherwise = current.text == "if" ? statement : block;
            }
            return s;
        }
        if (match("while"))
        {
            auto s = new Stmt(StmtKind.while_, location);
            s.expression = expression;
            newlines;
            s.body = block;
            return s;
        }
        if (match("for") || match("foreach"))
        {
            auto s = new Stmt(StmtKind.for_, location);
            s.name = identifier.text;
            expect("in");
            s.expression = expression;
            newlines;
            s.body = block;
            return s;
        }
        if (match("return"))
        {
            auto s = new Stmt(StmtKind.return_, location);
            if (current.kind != TokenKind.newline && current.text != ";" && current.text != "}")
                s.expression = expression;
            return s;
        }
        if (match("break"))
            return new Stmt(StmtKind.break_, location);
        if (match("continue"))
            return new Stmt(StmtKind.continue_, location);
        if (match("import"))
        {
            auto s = new Stmt(StmtKind.import_, location);
            if (current.kind != TokenKind.string_)
                fail("E_PARSE", "import requires a quoted module name", current.location);
            s.name = take.text;
            if (match("as"))
                s.annotation = identifier.text;
            return s;
        }
        if (match("action"))
        {
            auto s = new Stmt(StmtKind.action, location);
            if (current.text != "{" && current.kind != TokenKind.newline)
                s.expression = expression;
            newlines;
            s.body = block;
            return s;
        }
        if (current.kind == TokenKind.identifier && (current.text == "deps"
                || current.text == "monorepo"))
        {
            auto s = new Stmt(StmtKind.section, location);
            s.name = take.text;
            newlines;
            s.body = block;
            return s;
        }
        if (current.kind == TokenKind.identifier && (current.text == "dep"
                || current.text == "member" || current.text == "vendored" || current.text
                == "ignore"))
        {
            auto s = new Stmt(StmtKind.directive, location);
            s.name = take.text;
            auto call = new Expr(ExprKind.call, location);
            auto name = new Expr(ExprKind.name, location);
            name.text = s.name;
            call.left = name;
            call.entries ~= expression;
            call.names ~= "";
            while (current.kind == TokenKind.identifier && tokens[index + 1].text == ":")
            {
                auto key = take.text;
                expect(":");
                call.names ~= key;
                call.entries ~= expression;
                if (match(","))
                    newlines;
            }
            s.expression = call;
            return s;
        }
        auto s = new Stmt(StmtKind.expression, location);
        s.expression = expression;
        if (current.text == "=" || current.text == "+=" || current.text == "-="
                || current.text == "*=" || current.text == "/=")
        {
            s.name = take.text;
            newlines;
            s.extra = expression;
        }
        return s;
    }

    private int precedence(string op) @safe
    {
        switch (op)
        {
        case "or":
        case "||":
            return 1;
        case "and":
        case "&&":
            return 2;
        case "==":
        case "!=":
            return 3;
        case "<":
        case ">":
        case "<=":
        case ">=":
        case "in":
            return 4;
        case "..":
            return 5;
        case "+":
        case "-":
            return 6;
        case "*":
        case "/":
        case "%":
            return 7;
        default:
            return 0;
        }
    }

    Expr expression(int minimum = 1) @safe
    {
        auto lhs = unary;
        while (precedence(current.text) >= minimum)
        {
            auto op = take;
            newlines;
            auto rhs = expression(precedence(op.text) + 1);
            auto node = new Expr(ExprKind.binary, op.location);
            node.text = op.text;
            node.left = lhs;
            node.right = rhs;
            lhs = node;
        }
        return lhs;
    }

    private Expr unary() @safe
    {
        if (current.kind != TokenKind.string_ && (current.text == "!"
                || current.text == "not" || current.text == "-" || current.text == "+"))
        {
            auto op = take;
            if (op.text == "-" && current.kind == TokenKind.number
                    && current.text == "9223372036854775808")
            {
                take;
                auto literal = new Expr(ExprKind.literal, op.location);
                literal.literal = Value(long.min);
                return literal;
            }
            auto e = new Expr(ExprKind.unary, op.location);
            e.text = op.text;
            e.left = unary;
            return e;
        }
        auto e = primary;
        while (true)
        {
            if (match("("))
            {
                auto c = new Expr(ExprKind.call, e.location);
                c.left = e;
                newlines;
                while (!match(")"))
                {
                    string name;
                    if (current.kind == TokenKind.identifier && tokens[index + 1].text == ":")
                    {
                        name = take.text;
                        take;
                    }
                    if (name.length && c.names.canFind(name))
                        fail("E_PARSE", "duplicate named argument", current.location);
                    c.names ~= name;
                    c.entries ~= expression;
                    newlines;
                    if (!match(","))
                    {
                        expect(")");
                        break;
                    }
                    newlines;
                }
                e = c;
            }
            else if (match("."))
            {
                auto m = new Expr(ExprKind.member, e.location);
                m.left = e;
                m.text = identifier.text;
                e = m;
            }
            else if (match("["))
            {
                auto i = new Expr(ExprKind.index, e.location);
                i.left = e;
                i.right = expression;
                expect("]");
                e = i;
            }
            else
                break;
        }
        return e;
    }

    private Expr primary() @safe
    {
        auto t = take;
        auto e = new Expr(ExprKind.literal, t.location);
        if (t.kind == TokenKind.number)
        {
            try
            {
                e.literal = t.text.canFind('.') || t.text.canFind('e')
                    || t.text.canFind('E') ? Value(t.text.to!double) : Value(t.text.to!long);
            }
            catch (Exception)
            {
                fail("E_PARSE", "invalid or overflowing number", t.location);
            }
        }
        else if (t.kind == TokenKind.string_)
            e.literal = Value(t.text);
        else if (t.text == "true")
            e.literal = Value(true);
        else if (t.text == "false")
            e.literal = Value(false);
        else if (t.text == "nil")
            e.literal = Value.init;
        else if (t.text == "fn")
        {
            e.kind = ExprKind.function_;
            e.parameters = parameters;
            newlines;
            e.body = block;
        }
        else if (t.kind == TokenKind.identifier)
        {
            e.kind = ExprKind.name;
            e.text = t.text;
        }
        else if (t.text == "(")
        {
            newlines;
            e = expression;
            newlines;
            expect(")");
        }
        else if (t.text == "[")
        {
            e.kind = ExprKind.list;
            newlines;
            while (!match("]"))
            {
                e.entries ~= expression;
                newlines;
                if (!match(","))
                {
                    expect("]");
                    break;
                }
                newlines;
            }
        }
        else if (t.text == "{")
        {
            e.kind = ExprKind.map;
            newlines;
            while (!match("}"))
            {
                if (current.kind != TokenKind.string_ && current.kind != TokenKind.identifier)
                    fail("E_PARSE", "map keys must be strings", current.location);
                e.names ~= take.text;
                expect(":");
                e.entries ~= expression;
                newlines;
                if (!match(","))
                {
                    expect("}");
                    break;
                }
                newlines;
            }
        }
        else
            fail("E_PARSE", "expected expression, got '" ~ t.text ~ "'", t.location);
        return e;
    }
}
