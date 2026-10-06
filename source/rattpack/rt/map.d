module rattpack.rt.map;

import rattpack.diagnostic : Location, fail;
import rattpack.rt.sys;

// mapRegion and unmapRegion are defined once per platform under rt/<backend>/
// and re-exported through rattpack.rt.sys, the same way openLibrary is. They are
// deliberately not forward-declared here: D mangles a function by its defining
// module, so a declaration in this module would produce an unmatched symbol.

/// A whole file viewed through the operating system's mapping interface.
///
/// Used for large, repeatedly scanned binaries such as directory maps. The view
/// ends at close or destruction; copy out anything that must outlive it.
struct MappedFile
{
    private void* address;
    private size_t extent;
    /// Backend-owned state that must outlive the view, such as a Win32 section
    /// handle. Null on backends that need no extra resource.
    private void* backing;
    private bool mapped;

    /// Bytes visible through the mapping; empty for an empty or closed file.
    // TRUSTED: the backend reports the exact mapped extent, so this slice stays
    // inside the region obtained from the operating system.
    const(ubyte)[] view() const @trusted
    {
        return mapped ? cast(const(ubyte)[]) address[0 .. extent] : null;
    }

    /// Writable view; only mappings created writable may use this.
    // TRUSTED: as above, additionally guarded by the mapping's protection mode.
    void[] mutableView() @trusted
    {
        auto source = view();
        return cast(void[]) source;
    }

    /// True while the mapping is live.
    bool live() const @safe pure nothrow @nogc
    {
        return mapped;
    }

    /// Release the mapping. Safe to call more than once.
    // TRUSTED: the backend releases exactly the region and backing object this
    // mapping owns, in the order the platform requires.
    void close() @trusted
    {
        if (mapped)
        {
            unmapRegion(address, backing, extent);
            address = null;
            backing = null;
            extent = 0;
            mapped = false;
        }
    }

    ~this()
    {
        close();
    }
}

/// Map a file for reading, or for reading and writing when writable is set.
///
/// Zero-length files map successfully and yield an empty view. A missing or
/// unmappable path raises E_MAP.
// TRUSTED: the backend receives a valid path and a buffer sized for the message
// it writes; the returned extent comes from the operating system.
MappedFile mapFile(string path, bool writable = false) @trusted
{
    import std.string : fromStringz, strip;

    MappedFile result;
    char[512] reason;
    if (!mapRegion(path, writable, result.address, result.extent, result.backing,
            reason.ptr, reason.length))
        fail("E_MAP", "cannot memory-map " ~ path ~ ": "
                ~ fromStringz(reason.ptr).strip.idup, Location(path));
    result.mapped = true;
    return result;
}