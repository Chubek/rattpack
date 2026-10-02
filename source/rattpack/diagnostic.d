module rattpack.diagnostic;

import std.conv : to;

struct Location
{
    string file = "<input>";
    size_t line = 1;
    size_t column = 1;

    string toString() const @safe
    {
        return file ~ ":" ~ line.to!string ~ ":" ~ column.to!string;
    }
}

class Diagnostic : Exception
{
    string code;
    Location location;

    this(string code, string message, Location location = Location.init) @safe
    {
        this.code = code;
        this.location = location;
        super(location.toString ~ ": " ~ code ~ ": " ~ message);
    }
}

void fail(string code, string message, Location location = Location.init) @safe
{
    throw new Diagnostic(code, message, location);
}

alias WarningSink = void delegate(string code, string message, Location location);

void warning(string code, string message, Location location, bool asErrors, WarningSink sink)
{
    if (asErrors)
        fail(code, message, location);
    if (sink !is null)
        sink(code, message, location);
}
