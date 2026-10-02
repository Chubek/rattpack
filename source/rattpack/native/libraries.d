module rattpack.native.libraries;

import rattpack.diagnostic;
import std.string : toStringz, fromStringz;

extern (C)
{
    int ratt_git_checkout(const(char)* url, const(char)* directory,
            const(char)* revision, char* commit, char* error, size_t size);
    int ratt_decompress(const(ubyte)*, size_t, int, ubyte**, size_t*);
    void ratt_native_free(void*);
}
// TRUSTED: the bridge owns git objects, bounds both output buffers, and copies
// error text before releasing native storage. D strings stay live for the call.
string gitCheckout(string url, string directory, string revision) @trusted
{
    char[41] commit;
    char[2048] error;
    auto result = ratt_git_checkout(url.toStringz, directory.toStringz,
            revision.toStringz, commit.ptr, error.ptr, error.length);
    if (result)
        fail("E_PACKAGE", error.ptr.fromStringz.idup);
    return commit.ptr.fromStringz.idup;
}
// TRUSTED: the bridge returns an allocation and its exact length, which is
// copied into GC-owned storage before the allocation is freed on every path.
ubyte[] decompress(scope const(ubyte)[] bytes, bool xz) @trusted
{
    ubyte* output;
    size_t size;
    auto result = ratt_decompress(bytes.ptr, bytes.length, xz ? 1 : 0, &output, &size);
    scope (exit)
        ratt_native_free(output);
    if (result)
        fail("E_PACKAGE", "invalid or oversized compressed archive");
    return output[0 .. size].dup;
}
