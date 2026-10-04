module rattpack.script.evaluator;

import rattpack.diagnostic;
import rattpack.script.ast;
import rattpack.script.parser;
import rattpack.script.value;
import std.algorithm : sort, canFind;
import std.conv : to;
import std.path : absolutePath, dirName, buildPath, baseName, stripExtension, buildNormalizedPath;
import std.file : readText, exists;
import std.path : dirSeparator;
import std.string : startsWith, endsWith;
import rattpack.rt.common : ProcessResult;

Value binary(string op, Value a, Value b, Location loc) @safe
{
    if (op == "==")
        return Value(equal(a, b));
    if (op == "!=")
        return Value(!equal(a, b));
    if (op == "in")
    {
        if (b.kind == Value.Kind.map)
            return Value((a.text(loc) in b.data.mapValue.values) !is null);
        if (b.kind == Value.Kind.text)
            return Value(b.text.canFind(a.text(loc)));
        foreach (v; b.items(loc))
            if (equal(a, v))
                return Value(true);
        return Value(false);
    }
    if (op == "+")
    {
        if (a.kind == Value.Kind.text && b.kind == Value.Kind.text)
            return Value(a.text ~ b.text);
        if (a.kind == Value.Kind.list && b.kind == Value.Kind.list)
            return Value(a.items ~ b.items);
    }
    if (op == "..")
    {
        Value[] values;
        auto end = b.integer(loc);
        for (auto i = a.integer(loc); i < end; i++)
            values ~= Value(i);
        return Value(values);
    }
    if (op == "<" || op == ">" || op == "<=" || op == ">=")
    {
        int comparison;
        if (a.kind == Value.Kind.text && b.kind == Value.Kind.text)
            comparison = a.text < b.text ? -1 : a.text > b.text ? 1 : 0;
        else if (a.kind == Value.Kind.integer && b.kind == Value.Kind.integer)
            comparison = a.integer < b.integer ? -1 : a.integer > b.integer ? 1 : 0;
        else
        {
            auto x = a.number(loc), y = b.number(loc);
            if (op == "<")
                return Value(x < y);
            if (op == ">")
                return Value(x > y);
            if (op == "<=")
                return Value(x <= y);
            return Value(x >= y);
        }
        if (op == "<")
            return Value(comparison < 0);
        if (op == ">")
            return Value(comparison > 0);
        if (op == "<=")
            return Value(comparison <= 0);
        return Value(comparison >= 0);
    }
    if (a.kind == Value.Kind.integer && b.kind == Value.Kind.integer)
    {
        auto x = a.integer, y = b.integer;
        import core.checkedint : adds, subs, muls;

        bool overflow;
        long result;
        switch (op)
        {
        case "+":
            result = adds(x, y, overflow);
            break;
        case "-":
            result = subs(x, y, overflow);
            break;
        case "*":
            result = muls(x, y, overflow);
            break;
        case "/":
        case "%":
            if (!y)
                fail("E_RUNTIME", "division by zero", loc);
            if (x == long.min && y == -1)
                fail("E_RUNTIME", "integer overflow", loc);
            result = op == "/" ? x / y : x % y;
            break;
        default:
            fail("E_TYPE", "invalid operator " ~ op, loc);
        }
        if (overflow)
            fail("E_RUNTIME", "integer overflow", loc);
        return Value(result);
    }
    auto x = a.number(loc), y = b.number(loc);
    switch (op)
    {
    case "+":
        return Value(x + y);
    case "-":
        return Value(x - y);
    case "*":
        return Value(x * y);
    case "/":
        if (!y)
            fail("E_RUNTIME", "division by zero", loc);
        return Value(x / y);
    case "%":
        if (!y)
            fail("E_RUNTIME", "division by zero", loc);
        return Value(x % y);
    default:
        fail("E_TYPE", "invalid operator " ~ op, loc);
    }
    return Value.init;
}

enum Phase
{
    standalone,
    construction,
    execution
}

class Environment
{
    Environment parent;
    Value[string] values;
    string[string] annotations;
    this(Environment parent = null) @safe
    {
        this.parent = parent;
    }

    void define(string name, Value value, string annotation = "", Location loc = Location.init) @safe
    {
        if (name in values)
            fail("E_NAME", "duplicate binding '" ~ name ~ "'", loc);
        checkType(annotation, value, loc);
        values[name] = value;
        annotations[name] = annotation;
    }

    Value get(string name, Location loc = Location.init) @safe
    {
        if (auto v = name in values)
            return *v;
        if (parent !is null)
            return parent.get(name, loc);
        fail("E_NAME", "undefined name '" ~ name ~ "'", loc);
        return Value.init;
    }

    void assign(string name, Value value, Location loc) @safe
    {
        if (name in values)
        {
            checkType(annotations[name], value, loc);
            values[name] = value;
        }
        else if (parent !is null)
            parent.assign(name, value, loc);
        else
            fail("E_NAME", "undefined name '" ~ name ~ "'", loc);
    }
}

void checkType(string annotation, Value value, Location loc) @safe
{
    if (!annotation.length || annotation == "any")
        return;
    if (annotation != value.typeName && !(annotation == "float" && value.kind == Value.Kind.integer))
        fail("E_TYPE", "expected " ~ annotation ~ ", got " ~ value.typeName, loc);
}

class ReturnSignal : Exception
{
    Value value;
    this(Value value) @safe
    {
        super("return");
        this.value = value;
    }
}

class LoopSignal : Exception
{
    bool continueLoop;
    this(bool continueLoop) @safe
    {
        super("loop control");
        this.continueLoop = continueLoop;
    }
}

class UserFunction : Callable
{
    Evaluator evaluator;
    Environment closure;
    Parameter[] parameters;
    Stmt body;
    string annotation;
    this(Evaluator evaluator, Environment closure, string name,
            Parameter[] parameters, Stmt body, string annotation = "") @safe
    {
        this.evaluator = evaluator;
        this.closure = closure;
        this.name = name;
        this.parameters = parameters;
        this.body = body;
        this.annotation = annotation;
    }

    override Value call(Arguments args, Location loc)
    {
        if (args.positional.length > parameters.length)
            fail("E_ARITY", "too many arguments to " ~ name, loc);
        foreach (key; args.named.keys)
        {
            bool found;
            foreach (p; parameters)
                if (p.name == key)
                    found = true;
            if (!found)
                fail("E_ARITY", "unknown argument '" ~ key ~ "'", loc);
        }
        auto scope_ = new Environment(closure);
        foreach (i, p; parameters)
        {
            Value value;
            if (auto v = p.name in args.named)
            {
                if (i < args.positional.length)
                    fail("E_ARITY", "argument supplied twice: " ~ p.name, loc);
                value = *v;
            }
            else if (i < args.positional.length)
                value = args.positional[i];
            else if (p.defaultValue !is null)
                value = evaluator.eval(p.defaultValue, scope_);
            else
                fail("E_ARITY", "missing argument '" ~ p.name ~ "'", loc);
            scope_.define(p.name, value, p.annotation, loc);
        }
        Value result;
        try
        {
            evaluator.execute(body, scope_);
        }
        catch (ReturnSignal r)
        {
            result = r.value;
        }
        checkType(annotation, result, loc);
        return result;
    }
}

struct DeferredAction
{
    Value target;
    Stmt body;
    Environment closure;
    Location location;
}

class Evaluator
{
    Phase phase;
    Environment globals;
    Environment scriptScope;
    string cwd;
    string[] writeRoots;
    bool hermetic;
    string[] readableFiles;
    string[] writableFiles;
    bool environmentFrozen;
    string[string] processEnvironment;
    ProcessResult delegate(string[], string) processRunner;
    string delegate(string, string) sourceTransform;
    void delegate(string) output;
    Value delegate(string, Location) moduleLoader;
    void delegate(DeferredAction) actionHandler;
    Native[string] natives;
    Value[string] modules;
    bool[string] loading;
    private Stmt[string] parsed;

    void requireRead(string path, Location loc)
    {
        if (!hermetic)
            return;
        path = buildNormalizedPath(path);
        if (!readableFiles.canFind(path) && !writableFiles.canFind(path))
            fail("E_HERMETIC", "undeclared action input: " ~ path, loc);
        rejectSymlinks(path, loc);
    }

    private void rejectSymlinks(string path, Location loc)
    {
        import std.file : isSymlink;

        for (auto ancestor = path; ancestor.length; ancestor = dirName(ancestor))
        {
            if (exists(ancestor) && isSymlink(ancestor))
                fail("E_HERMETIC", "hermetic paths cannot traverse symlinks", loc);
            if (ancestor == dirName(ancestor))
                break;
        }
    }

    void requireWrite(string path, Location loc, bool directory = false)
    {
        if (hermetic)
        {
            path = buildNormalizedPath(path);
            rejectSymlinks(path, loc);
            foreach (file; writableFiles)
                if (path == file || (directory && file.startsWith(path ~ dirSeparator)))
                    return;
            fail("E_HERMETIC", "undeclared action output: " ~ path, loc);
        }
        if (!writeRoots.length)
            return;
        path = buildNormalizedPath(path);
        import std.file : isSymlink;

        auto ancestor = path;
        while (ancestor.length)
        {
            if (exists(ancestor) && isSymlink(ancestor))
                fail("E_ACTION", "sandbox writes cannot traverse symlinks", loc);
            auto parent = dirName(ancestor);
            if (parent == ancestor)
                break;
            ancestor = parent;
        }
        foreach (writeRoot; writeRoots)
        {
            auto root = buildNormalizedPath(writeRoot);
            if (path == root || path.startsWith(root ~ dirSeparator))
                return;
        }
        fail("E_ACTION", "action cannot write outside its declared output directories: " ~ path,
                loc);
    }

    this(Phase phase = Phase.standalone, string cwd = ".") @safe
    {
        this.phase = phase;
        this.cwd = buildNormalizedPath(absolutePath(cwd));
        globals = new Environment;
        scriptScope = new Environment(globals);
        installBuiltins;
    }

    Value native(string name, Value delegate(Arguments, Location) implementation,
            bool effectful = false) @safe
    {
        auto n = new Native(name, implementation, effectful);
        natives[name] = n;
        return Value(n);
    }

    void bind(string name, Value delegate(Arguments, Location) implementation, bool effectful = false) @safe
    {
        globals.values[name] = native(name, implementation, effectful);
    }

    Value invoke(Value function_, Arguments args, Location loc)
    {
        if (function_.kind != Value.Kind.function_)
            fail("E_TYPE", "value is not callable", loc);
        auto callable = function_.data.function_Value;
        if (callable.effectful && phase == Phase.construction)
            fail("E_PHASE_VIOLATION", callable.name ~ " is only permitted inside an action", loc);
        try
        {
            return callable.call(args, loc);
        }
        catch (Diagnostic d)
        {
            throw d;
        }
        catch (Exception e)
        {
            fail("E_RUNTIME", e.msg, loc);
        }
        return Value.init;
    }

    Value run(string source, string file = "<input>", Environment scope_ = null,
            bool preprocessSource = true)
    {
        if (preprocessSource && file.endsWith(".in") && sourceTransform !is null)
            source = sourceTransform(source, file);
        auto ast = new Parser(source, file).parse;
        if (scope_ is null)
            scope_ = scriptScope;
        try
        {
            return execute(ast, scope_);
        }
        catch (ReturnSignal)
        {
            fail("E_RUNTIME", "return outside a function", ast.location);
        }
        catch (LoopSignal)
        {
            fail("E_RUNTIME", "loop control outside a loop", ast.location);
        }
        return Value.init;
    }

    Value execute(Stmt s, Environment scope_)
    {
        Value result;
        final switch (s.kind)
        {
        case StmtKind.block:
            foreach (child; s.statements)
                result = execute(child, scope_);
            return result;
        case StmtKind.variable:
            scope_.define(s.name, eval(s.expression,
                    scope_), s.annotation, s.location);
            break;
        case StmtKind.function_:
            scope_.define(s.name,
                    Value(new UserFunction(this, scope_, s.name,
                        s.parameters, s.body, s.annotation)), "fn", s.location);
            break;
        case StmtKind.expression:
            if (!s.name.length)
                return eval(s.expression, scope_);
            result = eval(s.extra, scope_);
            if (s.name != "=")
                result = binary(s.name[0 .. 1], eval(s.expression, scope_), result, s.location);
            assign(s.expression, result, scope_);
            return result;
        case StmtKind.if_:
            if (eval(s.expression, scope_)
                    .truth)
                return execute(s.body, new Environment(scope_));
            if (s.otherwise !is null)
                return execute(s.otherwise, new Environment(scope_));
            break;
        case StmtKind.while_:
            while (eval(s.expression, scope_).truth)
            {
                try
                {
                    execute(s.body, new Environment(scope_));
                }
                catch (LoopSignal signal)
                {
                    if (!signal.continueLoop)
                        break;
                }
            }
            break;
        case StmtKind.for_:
            auto collection = eval(s.expression, scope_);
            Value[] values;
            if (collection.kind == Value.Kind.map)
                foreach (key; collection.data.mapValue.values.keys.sort)
                    values ~= Value(key);
            else if (collection.kind == Value.Kind.text)
                        foreach (dchar c; collection.text)
                            values ~= Value(c.to!string);
                    else
                        values = collection.items(s.location).dup;
            foreach (value; values)
            {
                auto loop = new Environment(scope_);
                loop.define(s.name, value);
                try
                {
                    execute(s.body, loop);
                }
                catch (LoopSignal signal)
                {
                    if (!signal.continueLoop)
                        break;
                }
            }
            break;
        case StmtKind.return_:
            throw new ReturnSignal(s.expression is null
                    ? Value.init : eval(s.expression, scope_));
        case StmtKind.break_:
            throw new LoopSignal(false);
        case StmtKind.continue_:
            throw new LoopSignal(true);
        case StmtKind.import_:
            auto name = s.annotation.length ? s.annotation
                : stripExtension(baseName(s.name.endsWith(".in") ? s.name[0 .. $ - 3] : s.name));
            scope_.define(name, importModule(s.name, s.location), "", s.location);
            break;
        case StmtKind.action:
            if (phase == Phase.construction)
            {
                if (actionHandler is null)
                    fail("E_PHASE_VIOLATION", "actions require a build target", s.location);
                actionHandler(DeferredAction(s.expression is null ? Value.init
                        : eval(s.expression, scope_), s.body, scope_, s.location));
            }
            else
                return execute(s.body, new Environment(scope_));
            break;
        case StmtKind.section:
            return execute(s.body, scope_);
        case StmtKind.directive:
            return eval(s.expression, scope_);
        }
        return result;
    }

    Value eval(Expr e, Environment scope_)
    {
        final switch (e.kind)
        {
        case ExprKind.literal:
            return e.literal;
        case ExprKind.name:
            return scope_.get(e.text, e.location);
        case ExprKind.list:
            Value[] entries;
            foreach (entry; e.entries)
                entries ~= eval(entry, scope_);
            return Value(entries);
        case ExprKind.map:
            Value[string] entries;
            foreach (i, entry; e.entries)
                entries[e.names[i]] = eval(entry, scope_);
            return Value(entries);
        case ExprKind.function_:
            return Value(new UserFunction(this, scope_,
                    "<anonymous>", e.parameters, e.body));
        case ExprKind.unary:
            auto value = eval(e.left, scope_);
            if (e.text == "!" || e.text == "not")
                return Value(!value.truth);
            if (e.text == "+")
            {
                value.number(e.location);
                return value;
            }
            if (value.kind == Value.Kind.integer)
            {
                if (value.integer == long.min)
                    fail("E_RUNTIME", "integer overflow", e.location);
                return Value(-value.integer);
            }
            return Value(-value.number(e.location));
        case ExprKind.binary:
            auto left = eval(e.left, scope_);
            if (e.text == "and" || e.text == "&&")
                return left.truth ? eval(e.right, scope_) : left;
            if (e.text == "or" || e.text == "||")
                return left.truth ? left : eval(e.right, scope_);
            return binary(e.text, left, eval(e.right, scope_), e.location);
        case ExprKind.member:
            return member(eval(e.left, scope_), e.text, e.location);
        case ExprKind.index:
            return indexValue(eval(e.left, scope_),
                    eval(e.right, scope_), e.location);
        case ExprKind.call:
            auto function_ = eval(e.left, scope_);
            Arguments args;
            foreach (i, entry; e.entries)
            {
                auto value = eval(entry, scope_);
                if (e.names[i].length)
                    args.named[e.names[i]] = value;
                else
                    args.positional ~= value;
            }
            return invoke(function_, args, e.location);
        }
    }

    private void assign(Expr e, Value value, Environment scope_)
    {
        if (e.kind == ExprKind.name)
        {
            scope_.assign(e.text, value, e.location);
            return;
        }
        if (e.kind == ExprKind.index || e.kind == ExprKind.member)
        {
            auto object = eval(e.left, scope_);
            auto key = e.kind == ExprKind.member ? Value(e.text) : eval(e.right, scope_);
            if (object.kind == Value.Kind.map)
            {
                object.data.mapValue.values[key.text(e.location)] = value;
                return;
            }
            if (object.kind == Value.Kind.list)
            {
                auto i = key.integer(e.location);
                auto values = object.items;
                if (i < 0)
                    i += values.length;
                if (i < 0 || i >= values.length)
                    fail("E_RUNTIME", "index out of bounds", e.location);
                object.data.listValue.values[cast(size_t) i] = value;
                return;
            }
        }
        fail("E_TYPE", "invalid assignment target", e.location);
    }

    Value member(Value object, string name, Location loc)
    {
        Value[string] fields;
        if (object.kind == Value.Kind.map)
            fields = object.data.mapValue.values;
        else if (object.kind == Value.Kind.target)
            fields = object.data.targetValue.fields;
        else if (object.kind == Value.Kind.rule)
            fields = object.data.ruleValue.fields;
        else if (object.kind == Value.Kind.pkg)
            fields = object.data.pkgValue.fields;
        if (auto value = name in fields)
            return *value;
        if (name == "length")
            return Value(cast(long) length(object, loc));
        if (object.kind == Value.Kind.list && name == "append")
        {
            auto fn = native("list.append", (Arguments a, Location l) {
                object.data.listValue.values ~= a.get("value", 0);
                return object;
            });
            auto bound = cast(Native) fn.data.function_Value;
            bound.bound = true;
            bound.receiver = object;
            bound.memberName = name;
            return fn;
        }
        fail("E_NAME", "unknown member '" ~ name ~ "'", loc);
        return Value.init;
    }

    Value indexValue(Value object, Value key, Location loc)
    {
        if (object.kind == Value.Kind.map)
        {
            if (auto v = key.text(loc) in object.data.mapValue.values)
                return *v;
            fail("E_NAME", "missing map key", loc);
        }
        auto i = key.integer(loc);
        auto count = length(object, loc);
        if (i < 0)
            i += count;
        if (i < 0 || i >= count)
            fail("E_RUNTIME", "index out of bounds", loc);
        if (object.kind == Value.Kind.text)
            return Value(object.text[cast(size_t) i .. cast(size_t) i + 1]);
        return object.items(loc)[cast(size_t) i];
    }

    private size_t length(Value v, Location loc) @safe
    {
        if (v.kind == Value.Kind.text || v.kind == Value.Kind.path)
            return v.text.length;
        if (v.kind == Value.Kind.map)
            return v.data.mapValue.values.length;
        return v.items(loc).length;
    }

    private void installBuiltins() @safe
    {
        bind("print", (Arguments a, Location l) {
            string text;
            foreach (i, v; a.positional)
            {
                if (i)
                    text ~= " ";
                text ~= v.str;
            }
            if (output !is null)
                output(text);
            return Value.init;
        });
        bind("assert", (Arguments a, Location l) {
            if (!a.get("condition", 0).truth)
                fail("E_RUNTIME", a.get("message", 1, Value("assertion failed")).str, l);
            return Value.init;
        });
        bind("len", (Arguments a, Location l) {
            return Value(cast(long) length(a.get("value", 0), l));
        });
        bind("type", (Arguments a, Location l) {
            return Value(a.get("value", 0).typeName);
        });
        bind("str", (Arguments a, Location l) {
            return Value(a.get("value", 0).str);
        });
        bind("int", (Arguments a, Location l) {
            auto v = a.get("value", 0);
            if (v.kind == Value.Kind.integer)
                return v;
            if (v.kind == Value.Kind.floating)
                return Value(cast(long) v.number);
            return Value(v.text(l).to!long);
        });
        bind("float", (Arguments a, Location l) {
            auto v = a.get("value", 0);
            if (v.kind == Value.Kind.integer || v.kind == Value.Kind.floating)
                return Value(v.number);
            return Value(v.text(l).to!double);
        });
        bind("set", (Arguments a, Location l) {
            return Value.set(a.get("values", 0, Value(cast(Value[])[])).items(l));
        });
        bind("range", (Arguments a, Location l) {
            long start = 0, end, step = 1;
            if (a.positional.length == 1)
                end = a.positional[0].integer(l);
            else
            {
                start = a.get("start", 0).integer(l);
                end = a.get("end", 1).integer(l);
            }
            step = a.get("step", 2, Value(1)).integer(l);
            if (!step)
                fail("E_RUNTIME", "range step cannot be zero", l);
            Value[] values;
            for (long i = start; step > 0 ? i < end : i > end; i += step)
                values ~= Value(i);
            return Value(values);
        });
        bind("sorted", (Arguments a, Location l) {
            auto values = a.get("values", 0).items(l).dup;
            values.sort!((x, y) => x.str < y.str);
            return Value(values);
        });
        bind("keys", (Arguments a, Location l) {
            auto v = a.get("map", 0);
            if (v.kind != Value.Kind.map)
                fail("E_TYPE", "keys expects map", l);
            Value[] values;
            foreach (key; v.data.mapValue.values.keys.sort)
                values ~= Value(key);
            return Value(values);
        });
    }

    Value importModule(string name, Location loc)
    {
        if (auto m = name in modules)
            return *m;
        if (moduleLoader !is null && !name.canFind('/') && !name.canFind('\\'))
        {
            auto value = moduleLoader(name, loc);
            modules[name] = value;
            return value;
        }
        if (["Rattspec", "Rattspec.m", "Rattspec.in", "Rattspec.m.in"].canFind(baseName(name)))
            fail("E_IMPORT", "spec discovery is automatic; do not import specs", loc);
        auto path = buildNormalizedPath(absolutePath(buildPath(dirName(loc.file) == "."
                ? cwd : dirName(loc.file), name)));
        requireRead(path, loc);
        if (!exists(path))
            fail("E_IMPORT", "module not found: " ~ path, loc);
        if (loading.get(path, false))
            fail("E_IMPORT", "cyclic module import: " ~ path, loc);
        if (auto m = path in modules)
            return *m;
        loading[path] = true;
        scope (exit)
            loading.remove(path);
        auto scope_ = new Environment(globals);
        if (!(path in parsed))
        {
            auto source = readText(path);
            if (path.endsWith(".in") && sourceTransform !is null)
                source = sourceTransform(source, path);
            parsed[path] = new Parser(source, path).parse;
        }
        execute(parsed[path], scope_);
        auto value = Value(scope_.values);
        modules[path] = value;
        return value;
    }
}
