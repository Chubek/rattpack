module rattpack.script.ast;

import rattpack.diagnostic;
import rattpack.script.value;

enum ExprKind
{
    literal,
    name,
    unary,
    binary,
    call,
    member,
    index,
    list,
    map,
    function_
}

class Expr
{
    ExprKind kind;
    Location location;
    string text;
    Value literal;
    Expr left;
    Expr right;
    Expr[] entries;
    string[] names;
    Parameter[] parameters;
    Stmt body;
    this(ExprKind kind, Location location) @safe
    {
        this.kind = kind;
        this.location = location;
    }
}

struct Parameter
{
    string name;
    string annotation;
    Expr defaultValue;
}

enum StmtKind
{
    expression,
    block,
    variable,
    function_,
    if_,
    while_,
    for_,
    return_,
    break_,
    continue_,
    import_,
    action,
    section,
    directive
}

class Stmt
{
    StmtKind kind;
    Location location;
    string name;
    string annotation;
    Expr expression;
    Expr extra;
    Stmt body;
    Stmt otherwise;
    Stmt[] statements;
    Parameter[] parameters;
    this(StmtKind kind, Location location) @safe
    {
        this.kind = kind;
        this.location = location;
    }
}
