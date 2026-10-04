module rattpack.content.hash;

import rattpack.native.blake3;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : read, exists, isDir;
import std.path : relativePath, baseName;
import std.string : toLower, replace;
import rattpack.rt.sys : sortedFiles, linkTarget, executableFile;

// TRUSTED: the C hasher receives only valid slice bounds and correctly sized
// stack objects whose layouts match the pinned blake3.h declarations.
string hashBytes(scope const(void)[] bytes) @trusted
{
    Blake3Hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, bytes.ptr, bytes.length);
    ubyte[32] digest;
    blake3_hasher_finalize(&hasher, digest.ptr, digest.length);
    return digest.toHexString.toLower;
}

string hashParts(scope string[] parts) @safe
{
    import std.conv : to;

    string data;
    foreach (part; parts)
        data ~= part.length.to!string ~ ":" ~ part;
    return hashBytes(data);
}

string hashFile(string path)
{
    return exists(path) ? hashBytes(read(path)) : hashBytes("<missing>" ~ path);
}

string sha256(scope const(void)[] bytes) @safe
{
    auto digest = sha256Of(cast(const(ubyte)[]) bytes);
    return digest.toHexString.idup.toLower;
}

string hashTree(string root)
{
    string[] parts;
    import std.file : dirEntries, SpanMode;

    string[] entries;
    foreach (entry; dirEntries(root, SpanMode.depth))
        entries ~= entry.name;
    import std.algorithm : sort;

    foreach (path; entries.sort)
    {
        auto relative = relativePath(path, root).replace("\\", "/");
        if (relative == ".git" || (relative.length > 5 && relative[0 .. 5] == ".git/"))
            continue;
        import std.file : isSymlink;

        parts ~= relative;
        if (isSymlink(path))
        {
            parts ~= "link";
            parts ~= linkTarget(path);
        }
        else if (isDir(path))
            parts ~= "directory";
        else
        {
            parts ~= executableFile(path) ? "executable" : "file";
            parts ~= sha256(read(path));
        }
    }
    string data;
    import std.conv : to;

    foreach (part; parts)
        data ~= part.length.to!string ~ ":" ~ part;
    return sha256(data);
}

import std.string : join;
