module rattpack.script.lint;

import rattpack.script.ast;
import rattpack.diagnostic;
import std.algorithm : canFind;
import rattpack.script.parser : Parser;
import std.file : readText, exists;
import std.path : absolutePath, dirName, baseName, buildNormalizedPath;
import std.string : endsWith;

private class Types
{
    Types parent;
    string[string] bindings;
    Stmt[string] functions;
    this(Types parent = null) @safe
    {
        this.parent = parent;
    }

    string get(string name) @safe
    {
        if (auto v = name in bindings)
            return *v;
        return parent is null ? "any" : parent.get(name);
    }
}

private void validate(string type, Location loc) @safe
{
    if (type.length && ![
        "any", "nil", "bool", "int", "float", "str", "path", "list", "map",
        "set", "fn", "target", "rule", "pkg"
    ].canFind(type))
        fail("E_TYPE", "unknown annotation '" ~ type ~ "'", loc);
}

private void compatible(string expected, string actual, Location loc) @safe
{
    validate(expected, loc);
    if (expected.length && expected != "any" && actual != "any"
            && expected != actual && !(expected == "float" && actual == "int"))
        fail("E_TYPE", "expected " ~ expected ~ ", got " ~ actual, loc);
}

private string infer(Expr e, Types scope_) @safe
{
    if (e is null)
        return "nil";
    final switch (e.kind)
    {
    case ExprKind.literal:
        return e.literal.typeName;
    case ExprKind.name:
        return scope_.get(e.text);
    case ExprKind.list:
        foreach (entry; e.entries)
            infer(entry, scope_);
        return "list";
    case ExprKind.map:
        foreach (entry; e.entries)
            infer(entry, scope_);
        return "map";
    case ExprKind.function_:
        lintFunction(e.parameters, e.body, "", scope_);
        return "fn";
    case ExprKind.unary:
        auto type = infer(e.left, scope_);
        if (e.text == "!" || e.text == "not")
            return "bool";
        if (type != "any" && type != "int" && type != "float")
            fail("E_TYPE", "unary operator expects number", e.location);
        return type;
    case ExprKind.binary:
        auto a = infer(e.left, scope_), b = infer(e.right, scope_);
        if (["==", "!=", "<", ">", "<=", ">=", "in"].canFind(e.text))
            return "bool";
        if (e.text == "..")
            return "list";
        if (["and", "or", "&&", "||"].canFind(e.text))
            return a == b ? a : "any";
        if (a == "any" || b == "any")
            return "any";
        if (e.text == "+" && a == b && (a == "str" || a == "list"))
            return a;
        if ((a == "int" || a == "float") && (b == "int" || b == "float"))
            return a == "float" || b == "float" ? "float" : "int";
        fail("E_TYPE", "incompatible operator operands", e.location);
        return "any";
    case ExprKind.member:
        infer(e.left, scope_);
        return e.text == "length" ? "int" : "any";
    case ExprKind.index:
        infer(e.left, scope_);
        infer(e.right, scope_);
        return "any";
    case ExprKind.call:
        infer(e.left, scope_);
        foreach (entry; e.entries)
            infer(entry, scope_);
        if (e.left.kind == ExprKind.name)
        {
            auto name = e.left.text;
            if (["int", "float", "str", "set"].canFind(name))
                return name;
            if (name == "len")
                return "int";
            if (name == "type")
                return "str";
            if (name == "range" || name == "sorted" || name == "keys")
                return "list";
            for (auto scope2 = scope_; scope2 !is null; scope2 = scope2.parent)
                if (auto f = name in scope2.functions)
                {
                    foreach (i, entry; e.entries)
                    {
                        auto parameter = i;
                        if (e.names[i].length)
                            foreach (j, p; (*f).parameters)
                                if (p.name == e.names[i])
                                    parameter = j;
                        if (parameter < (*f).parameters.length)
                            compatible((*f).parameters[parameter].annotation,
                                    infer(entry, scope_), entry.location);
                    }
                    return (*f).annotation.length ? (*f).annotation : "any";
                }
        }
        return "any";
    }
}

private void lintFunction(Parameter[] parameters, Stmt body, string result, Types outer) @safe
{
    auto scope_ = new Types(outer);
    validate(result, body.location);
    foreach (p; parameters)
    {
        validate(p.annotation, body.location);
        if (p.defaultValue !is null)
            compatible(p.annotation, infer(p.defaultValue, scope_), body.location);
        scope_.bindings[p.name] = p.annotation.length ? p.annotation : "any";
    }
    walk(body, scope_, result);
}

private void walk(Stmt s, Types scope_, string result = "") @safe
{
    final switch (s.kind)
    {
    case StmtKind.block:
        foreach (child; s.statements)
            if (child.kind == StmtKind.function_)
            {
                scope_.functions[child.name] = child;
                scope_.bindings[child.name] = "fn";
            }
        foreach (child; s.statements)
            walk(child, scope_, result);
        break;
    case StmtKind.variable:
        auto actual = infer(s.expression, scope_);
        compatible(s.annotation, actual, s.location);
        scope_.bindings[s.name] = s.annotation.length ? s.annotation : actual;
        break;
    case StmtKind.function_:
        lintFunction(s.parameters, s.body, s.annotation, scope_);
        break;
    case StmtKind.return_:
        compatible(result, infer(s.expression, scope_), s.location);
        break;
    case StmtKind.expression:
        infer(s.expression, scope_);
        if (s.extra !is null)
            compatible(infer(s.expression, scope_), infer(s.extra, scope_), s.location);
        break;
    case StmtKind.if_:
    case StmtKind.while_:
        infer(s.expression, scope_);
        walk(s.body, new Types(scope_), result);
        if (s.otherwise !is null)
            walk(s.otherwise, new Types(scope_), result);
        break;
    case StmtKind.for_:
        infer(s.expression, scope_);
        auto loop = new Types(scope_);
        loop.bindings[s.name] = "any";
        walk(s.body, loop, result);
        break;
    case StmtKind.action:
        walk(s.body, new Types(scope_));
        break;
    case StmtKind.import_:
        scope_.bindings[s.annotation.length ? s.annotation : s.name] = "map";
        break;
    case StmtKind.section:
        walk(s.body, scope_, result);
        break;
    case StmtKind.directive:
        infer(s.expression, scope_);
        break;
    case StmtKind.break_:
    case StmtKind.continue_:
        break;
    }
}

void lint(Stmt ast) @safe
{
    walk(ast, new Types);
}

/// Check a file and its statically imported source modules without executing them.
/// The transform, when supplied, preprocesses .in sources before parsing.
void lintFile(string path, string delegate(string, string) transform = null)
{
    bool[string] checked, loading;
    void checkFile(string file, Location location)
    {
        file = buildNormalizedPath(absolutePath(file));
        if (loading.get(file, false))
            fail("E_IMPORT", "cyclic module import: " ~ file, location);
        if (checked.get(file, false))
            return;
        if (!exists(file))
            fail("E_IMPORT", "module not found: " ~ file, location);
        loading[file] = true;
        scope (exit)
            loading.remove(file);
        auto source = readText(file);
        if (file.endsWith(".in") && transform !is null)
            source = transform(source, file);
        auto ast = new Parser(source, file).parse;
        lint(ast);
        void delegate(Stmt) visitStatement;
        void visitExpression(Expr expression)
        {
            if (expression is null)
                return;
            visitExpression(expression.left);
            visitExpression(expression.right);
            foreach (entry; expression.entries)
                visitExpression(entry);
            foreach (parameter; expression.parameters)
                visitExpression(parameter.defaultValue);
            visitStatement(expression.body);
        }

        visitStatement = (Stmt statement) {
            if (statement is null)
                return;
            if (statement.kind == StmtKind.import_
                    && (statement.name.canFind('/') || statement.name.canFind('\\')))
            {
                if (["Rattspec", "Rattspec.m", "Rattspec.in",
                        "Rattspec.m.in"].canFind(baseName(statement.name)))
                    fail("E_IMPORT", "spec discovery is automatic; do not import specs",
                            statement.location);
                checkFile(absolutePath(statement.name, dirName(file)), statement.location);
            }
            foreach (child; statement.statements)
                visitStatement(child);
            foreach (parameter; statement.parameters)
                visitExpression(parameter.defaultValue);
            visitExpression(statement.expression);
            visitExpression(statement.extra);
            visitStatement(statement.body);
            visitStatement(statement.otherwise);
        };

        visitStatement(ast);
        checked[file] = true;
    }

    checkFile(path, Location(path));
}
