module rattpack.constraints;

import rattpack.diagnostic : fail;
import rattpack.rt.sys : executableSuffix;
import std.array : array;
import std.algorithm : map;
import std.conv : to;
import std.file : thisExePath;
import std.path : buildPath, dirName;
import std.process : pipeProcess, Redirect, wait, kill;
import std.string : join, splitLines, strip;

/// Solve CNF with deterministic, true-first preferences. An empty clause is false.
/// The helper is installed beside the host executable; no PATH lookup or shell.
bool solveConstraints(int[][] clauses, int[] preferences, out int[] selected) @safe
{
    foreach (clause; clauses)
        if (!clause.length)
            return false;
    string request = preferences.map!(v => v.to!string).array.join(" ") ~ "\n";
    foreach (clause; clauses)
        request ~= clause.map!(v => v.to!string).array.join(" ") ~ "\n";
    string output;
    try
        output = invokeSolver(request);
    catch (Exception error)
        fail("E_PACKAGE", "cannot run ratt-satie beside the host executable: " ~ error.msg);
    auto response = output.strip.splitLines;
    if (response.length && response[0] == "UNSAT")
        return false;
    if (!response.length || response[0] != "SAT")
        fail("E_PACKAGE", "invalid response from ratt-satie");
    foreach (line; response[1 .. $])
        selected ~= line.to!int;
    return true;
}

private string invokeSolver(string request) @trusted
{
    // TRUSTED: owned pipes and buffers stay inside this synchronous invocation;
    // the executable path is absolute and arguments never pass through a shell.
    auto process = pipeProcess([
        buildPath(dirName(thisExePath), "ratt-satie" ~ executableSuffix)
    ], Redirect.all);
    bool reaped;
    scope (failure)
    {
        if (!reaped)
        {
            kill(process.pid);
            wait(process.pid);
        }
    }
    scope (exit)
    {
        process.stdin.close();
        process.stdout.close();
        process.stderr.close();
    }
    process.stdin.write(request);
    process.stdin.close();
    string response;
    foreach (line; process.stdout.byLine())
        response ~= line.idup ~ "\n";
    string errors;
    foreach (line; process.stderr.byLine())
        errors ~= line.idup ~ "\n";
    auto status = wait(process.pid);
    reaped = true;
    if (status != 0)
        fail("E_PACKAGE", "ratt-satie failed: " ~ errors.strip);
    return response;
}
