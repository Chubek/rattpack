module rattpack.rt.common;

import std.algorithm : sort;
import std.file;
import std.path;
import std.process;
import std.string : splitLines;

struct ProcessResult
{
    int status;
    string output;
}

ProcessResult runProcess(string[] argv, string cwd = null, string[string] env = null)
{
    auto result = execute(argv, env, Config.none, size_t.max, cwd);
    return ProcessResult(result.status, result.output);
}

string[] sortedFiles(string root, bool recursive = true)
{
    string[] result;
    if (!exists(root))
        return result;
    foreach (entry; dirEntries(root, recursive ? SpanMode.depth : SpanMode.shallow))
        if (entry.isFile && !entry.isSymlink)
            result ~= entry.name;
    result.sort;
    return result;
}

void atomicWrite(string path, const(void)[] contents)
{
    auto parent = dirName(path);
    if (parent.length)
        mkdirRecurse(parent);
    // The temporary file is exclusively created; unrelated writers cannot
    // overwrite it. rename is the backend's atomic replacement operation.
    import std.stdio : File;
    import std.random : uniform;

    string temporary;
    File file;
    foreach (_; 0 .. 100)
    {
        temporary = path ~ ".tmp-" ~ uniform(0UL, ulong.max).toHex;
        try
        {
            file = File(temporary, "wbx");
            break;
        }
        catch (Exception)
        {
        }
    }
    if (!file.isOpen)
        throw new FileException(path, "cannot create temporary file");
    scope (exit)
        if (exists(temporary))
            remove(temporary);
    file.rawWrite(cast(const(ubyte)[]) contents);
    file.flush;
    file.close;
    rename(temporary, path);
}

private string toHex(ulong value) @safe
{
    import std.format : format;

    return format("%016x", value);
}

string findProgram(string name, string pathEnvironment)
{
    if (isAbsolute(name) || name.canFind(dirSeparator))
        return exists(name) ? absolutePath(name) : "";
    foreach (directory; pathEnvironment.split(pathSeparator))
    {
        auto candidate = buildPath(directory, name);
        if (exists(candidate) && isFile(candidate))
            return absolutePath(candidate);
        auto executable = candidate ~ ".exe";
        if (exists(executable) && isFile(executable))
            return absolutePath(executable);
    }
    return "";
}

import std.algorithm.searching : canFind;
import std.string : split;
