module rattpack.dirmap;

import rattpack.content.hash : hashBytes;
import rattpack.diagnostic : Location, fail;
import rattpack.rt.common : atomicWrite;
import rattpack.rt.map : MappedFile, mapFile;
import std.algorithm : canFind, sort;
import std.array : replicate;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, getSize, isDir, isFile, isSymlink, read;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, extension,
        relativePath;
import std.string : join, replace, toLower;

/// Magic and layout version of the on-disk map.
enum string mapMagic = "RATTDMAP";
enum uint mapVersion = 1;
enum size_t mapHeaderSize = 72;
enum size_t mapNodeSize = 24;

/// Entry classification. The text DSL letter is derived from these values so the
/// binary and terse forms cannot drift apart.
enum DirKind : ubyte
{
    file = 0,
    directory = 1,
    link = 2,
    other = 3
}

/// One mapped entry. Nodes are stored in depth-first preorder, so a subtree is a
/// contiguous run and the text form needs no explicit end markers.
struct DirNode
{
    string name;
    DirKind kind;
    bool executable;
    bool hidden;
    uint depth;
    /// Number of file descendants, used for directory summaries.
    uint fileCount;
    /// Saturating size in bytes.
    uint size;
    /// Truncated content fingerprint, for noticing what changed.
    uint contentId;
}

/// A directory described by name, kind, size, and content fingerprints.
///
/// A map is a compact inventory: enough to reason about a project's shape and to
/// see what changed, without carrying any file contents.
struct DirMap
{
    string root;
    DirNode[] nodes;
    uint totalBytes;
    /// Identity of the scanned set of fingerprinted files.
    string contentHash;
}

/// Directories never worth mapping: version-control metadata, build outputs,
/// dependency caches, and editor scratch state.
private static immutable skippedDirectories = [
    ".git", ".hg", ".svn", ".dub", ".rattpack", "build", "node_modules",
    "__pycache__", ".cache", ".venv", "venv", ".idea", ".vscode"
];

/// Extensions whose contents are fingerprinted. Hashing every byte of a large
/// tree costs far more than it is worth; these are the files a reviewer or model
/// actually reasons about.
private static immutable fingerprintedExtensions = [
    ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".d", ".di", ".ratt",
    ".in", ".json", ".toml", ".yaml", ".yml", ".md", ".txt", ".py", ".sh",
    ".sdl", ".vim", ".lua", ".cmake", ".s", ".asm"
];

/// Scan a directory tree. Entries are ordered deterministically.
DirMap scanDirectory(string directory)
{
    auto root = buildNormalizedPath(absolutePath(directory));
    if (!exists(root) || !isDir(root))
        fail("E_MAP", "not a directory: " ~ root, Location(root));
    DirMap result;
    result.root = baseName(root);
    string[] fingerprinted;
    // Nodes are appended in depth-first preorder. A directory's node is created
    // by its parent; this function then fills in its children and totals, so a
    // subtree is always a contiguous run of indices.
    void visit(string parent, size_t self, uint depth)
    {
        string[] entries;
        foreach (entry; dirEntries(parent, SpanMode.shallow))
        {
            auto name = baseName(entry.name);
            if (name.length && name[0] == '.')
                continue;
            if (skippedDirectories.canFind(name))
                continue;
            entries ~= entry.name;
        }
        entries.sort;
        foreach (path; entries)
        {
            auto name = baseName(path);
            DirNode node;
            node.name = name;
            node.depth = depth;
            bool descend;
            if (isSymlink(path))
                node.kind = DirKind.link;
            else if (isDir(path))
            {
                node.kind = DirKind.directory;
                descend = true;
            }
            else if (isFile(path))
                node.kind = DirKind.file;
            else
                node.kind = DirKind.other;
            if (node.kind == DirKind.file)
            {
                import rattpack.rt.sys : executableFile;

                node.executable = executableFile(path);
                auto size = fileSize(path);
                node.size = size > uint.max ? uint.max : cast(uint) size;
                result.totalBytes += node.size;
                result.nodes[self].fileCount++;
                result.nodes[self].size += node.size;
                if (fingerprintedExtensions.canFind(extension(name).toLower))
                {
                    node.contentId = contentFingerprint(read(path));
                    fingerprinted ~= relativePath(path, root).replace("\\", "/");
                }
            }
            result.nodes ~= node;
            auto childIndex = cast(size_t) (result.nodes.length - 1u);
            if (descend)
            {
                visit(path, childIndex, depth + 1);
                // Directory totals cover the whole subtree, so one number
                // summarises a directory instead of its immediate children.
                result.nodes[self].fileCount += result.nodes[childIndex].fileCount;
                result.nodes[self].size += result.nodes[childIndex].size;
            }
        }
    }
    DirNode rootNode;
    rootNode.name = baseName(root);
    rootNode.kind = DirKind.directory;
    result.nodes ~= rootNode;
    visit(root, 0, 1);
    fingerprinted.sort;
    result.contentHash = hashBytes(fingerprinted.join("\n"));
    return result;
}

private size_t fileSize(string path)
{
    auto size = getSize(path);
    return size < 0 ? 0 : cast(size_t) size;
}

/// Eight hex digits of BLAKE3 over the file's bytes.
private uint contentFingerprint(scope const(void)[] bytes)
{
    auto digest = hashBytes(bytes);
    uint value;
    foreach (i; 0 .. 8)
        value = (value << 4) | hexDigit(digest[i]);
    return value;
}

private uint hexDigit(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return 0;
}

/// Serialize a map. Fixed-width little-endian fields keep the layout readable
/// through a mapping on every supported platform.
ubyte[] encodeDirMap(DirMap map)
{
    // Intern names so repeated directories such as test/ or include/ cost once.
    // Each name is NUL-terminated so the reader can find its end without a
    // separate length table.
    uint[string] interned;
    ubyte[] names;
    uint[] offsets;
    foreach (node; map.nodes)
        if (auto existing = node.name in interned)
            offsets ~= *existing;
        else
        {
            offsets ~= cast(uint) names.length;
            interned[node.name] = cast(uint) names.length;
            names ~= node.name.dup;
            names ~= 0;
        }
    auto payload = map.nodes.length * mapNodeSize;
    auto result = new ubyte[mapHeaderSize + payload + names.length];
    void put(size_t offset, uint value)
    {
        foreach (i; 0 .. 4)
            result[offset + i] = cast(ubyte) ((value >> (i * 8)) & 0xff);
    }
    result[0 .. 8] = cast(ubyte[]) mapMagic.dup;
    put(8, mapVersion);
    put(12, cast(uint) map.nodes.length);
    put(16, cast(uint) interned.length);
    put(20, cast(uint) names.length);
    put(24, 0); // reserved
    put(28, map.totalBytes);
    // Node table and name table offsets, so the reader can bounds-check.
    put(32, cast(uint) mapHeaderSize);
    put(36, cast(uint) (mapHeaderSize + payload));
    put(40, 0); // the root is node zero by construction
    put(44, 0); // reserved
    foreach (i, node; map.nodes)
    {
        auto base = mapHeaderSize + i * mapNodeSize;
        put(base, offsets[i]);
        result[base + 4] = cast(ubyte) node.kind;
        result[base + 5] = cast(ubyte) (node.executable ? 1 : 0);
        put(base + 8, node.fileCount);
        put(base + 12, node.size);
        put(base + 16, node.contentId);
        put(base + 20, node.depth);
    }
    result[mapHeaderSize + payload .. $] = names;
    return result;
}

/// Write a map atomically so a reader never observes a partial file.
void writeDirMap(string path, DirMap map)
{
    atomicWrite(path, encodeDirMap(map));
}

/// A map read back through its memory mapping.
struct MappedDirMap
{
    private MappedFile file;
    private const(ubyte)[] raw;
    private uint nodeCount;
    private uint nameBytes;
    private uint nodeStart;
    private uint nameStart;

    /// Map a previously written map file and validate its structure.
    static MappedDirMap open(string path)
    {
        MappedDirMap result;
        result.file = mapFile(path);
        result.raw = result.file.view();
        if (result.raw.length < mapHeaderSize)
            fail("E_MAP", "truncated directory map: " ~ path, Location(path));
        if (cast(string) result.raw[0 .. 8] != mapMagic)
            fail("E_MAP", "not a Rattpack directory map: " ~ path, Location(path));
        auto fileVersion = readUint(result.raw, 8);
        if (fileVersion != mapVersion)
            fail("E_MAP", "unsupported directory map version " ~ fileVersion.to!string
                    ~ " in " ~ path, Location(path));
        result.nodeCount = readUint(result.raw, 12);
        result.nameBytes = readUint(result.raw, 20);
        result.nodeStart = readUint(result.raw, 32);
        result.nameStart = readUint(result.raw, 36);
        auto expected = result.nodeStart + result.nodeCount * mapNodeSize + result.nameBytes;
        if (result.nodeStart < mapHeaderSize || expected > result.raw.length)
            fail("E_MAP", "inconsistent directory map: " ~ path, Location(path));
        return result;
    }

    /// True while the mapping is live.
    bool live() @safe
    {
        return file.live;
    }

    /// Number of mapped entries, including the root.
    size_t length() @safe pure nothrow @nogc
    {
        return nodeCount;
    }

    /// Decoded entry at index.
    DirNode node(size_t index)
    {
        if (index >= nodeCount)
            fail("E_MAP", "directory map index out of range");
        auto base = nodeStart + index * mapNodeSize;
        DirNode result;
        result.name = readName(readUint(raw, base));
        result.kind = cast(DirKind) raw[base + 4];
        result.executable = raw[base + 5] != 0;
        result.fileCount = readUint(raw, base + 8);
        result.size = readUint(raw, base + 12);
        result.contentId = readUint(raw, base + 16);
        result.depth = readUint(raw, base + 20);
        return result;
    }

    /// Release the mapping.
    void close()
    {
        file.close;
    }

    private string readName(uint offset)
    {
        if (offset >= nameBytes)
            fail("E_MAP", "directory map name offset out of range");
        auto start = nameStart + offset;
        auto end = start;
        while (end < raw.length && raw[end])
            end++;
        return cast(string) raw[start .. end].idup;
    }

    private static uint readUint(const(ubyte)[] data, size_t offset)
    {
        uint value;
        foreach (i; 0 .. 4)
            value |= cast(uint) data[offset + i] << (i * 8);
        return value;
    }

    ~this()
    {
        close;
    }
}

/// Default cache path for a directory: $XDG_CACHE_HOME/rattpack/<name>.bin.
string dirMapCachePath(string directory)
{
    import rattpack.rt.sys : cacheHome;

    auto root = buildNormalizedPath(absolutePath(directory));
    return buildPath(cacheHome(), "rattpack", baseName(root) ~ ".bin");
}

/// Render one map in the terse map DSL: one entry per line, indented by depth.
///
/// Grammar, where the leading letter is the entry kind:
///
///   d NAME[:F COUNT][:B BYTES]   directory with optional file and byte totals
///   f NAME[:X][:BYTES][:HASH]    file; X marks an executable
///   l NAME                       symbolic link
///   x NAME                       any other entry kind
///
/// The colon separates a name from its attributes, so one space of indentation
/// per level can never merge into the name. Inside a name, a backslash escapes a
/// backslash, a colon, or a space. BYTES uses k and M suffixes and HASH is eight
/// lowercase hex digits, so a large tree stays inside a small prompt budget.
string renderDirMap(DirMap map, bool summary = true)
{
    string result;
    foreach (node; map.nodes)
        result ~= renderNode(node, summary);
    return result;
}

/// Render a mapped map without materialising a scanned structure first.
string renderMappedDirMap(MappedDirMap map, bool summary = true)
{
    string result;
    foreach (index; 0 .. map.length)
        result ~= renderNode(map.node(index), summary);
    return result;
}

/// Escape the characters that would otherwise end a name.
private string encodeName(string name) @safe
{
    string result;
    foreach (c; name)
    {
        if (c == '\\' || c == ':' || c == ' ')
            result ~= '\\';
        result ~= c;
    }
    return result;
}

private string renderNode(DirNode node, bool summary) @safe
{
    auto result = replicate(" ", node.depth);
    switch (node.kind)
    {
    case DirKind.directory:
        result ~= "d " ~ encodeName(node.name);
        if (summary && node.fileCount)
            result ~= ":F" ~ node.fileCount.to!string;
        if (summary && node.size)
            result ~= ":B" ~ shortBytes(node.size);
        break;
    case DirKind.file:
        result ~= "f " ~ encodeName(node.name);
        if (node.executable)
            result ~= ":X";
        result ~= ":" ~ shortBytes(node.size) ~ ":" ~ shortHash(node.contentId);
        break;
    case DirKind.link:
        result ~= "l " ~ encodeName(node.name);
        break;
    case DirKind.other:
        result ~= "x " ~ encodeName(node.name);
        break;
    default:
        // A corrupted map must not be able to abort rendering.
        break;
    }
    return result ~ "\n";
}

private string shortBytes(uint size) @safe
{
    if (size >= 1024 * 1024)
        return format("%.1fM", size / (1024.0 * 1024.0));
    if (size >= 1024)
        return format("%.1fk", size / 1024.0);
    return size.to!string;
}

private string shortHash(uint value) @safe
{
    return format("%08x", value);
}