module rattpack.pkg.archive;

import rattpack.native.libraries : decompress;
import rattpack.diagnostic;
import rattpack.rt.sys : atomicWrite, setExecutable;
import std.file;
import std.path;
import std.string;
import std.conv : to;
import std.zip;

private string safePath(string root, string name)
{
    name = name.replace("\\", "/");
    if (name.length && (name[0] == '/' || name.canFind(':') || name.split('/').canFind("..")))
        fail("E_PACKAGE", "archive entry escapes its destination: " ~ name);
    auto path = absolutePath(buildNormalizedPath(name), root);
    if (path != root && !path.startsWith(root ~ dirSeparator))
        fail("E_PACKAGE", "unsafe archive path");
    return path;
}

private string field(const(ubyte)[] bytes)
{
    auto end = bytes.countUntil(cast(ubyte) 0);
    return cast(string) bytes[0 .. end < 0 ? $ : cast(size_t) end].idup;
}

private size_t octal(const(ubyte)[] bytes)
{
    auto value = field(bytes).strip;
    size_t result;
    foreach (c; value)
    {
        if (c < '0' || c > '7' || result > size_t.max / 8)
            fail("E_PACKAGE", "invalid tar size");
        result = result * 8 + c - '0';
    }
    return result;
}

void extractArchive(const(ubyte)[] input, string destination)
{
    auto root = absolutePath(destination);
    mkdirRecurse(root);
    if (input.length >= 4 && input[0 .. 4] == [0x50, 0x4b, 0x03, 0x04])
    {
        auto archive = new ZipArchive(input.dup);
        foreach (name; archive.directory.keys.sort)
        {
            auto member = archive.directory[name];
            auto path = safePath(root, name);
            auto mode = member.fileAttributes;
            if ((mode & 0xF000) == 0xA000)
                fail("E_PACKAGE", "archive symlinks are unsupported");
            if (name.endsWith("/"))
                mkdirRecurse(path);
            else
            {
                atomicWrite(path, archive.expand(member));
                setExecutable(path, (mode & 73) != 0);
            }
        }
        return;
    }
    ubyte[] storage;
    const(ubyte)[] bytes = input;
    if (input.length >= 2 && input[0] == 0x1f && input[1] == 0x8b)
    {
        storage = decompress(input, false);
        bytes = storage;
    }
    else if (input.length >= 6 && input[0 .. 6] == [
        0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00
    ])
    {
        storage = decompress(input, true);
        bytes = storage;
    }
    size_t offset;
    string nextName;
    string paxName;
    while (offset + 512 <= bytes.length)
    {
        auto header = bytes[offset .. offset + 512];
        offset += 512;
        if (header.all!(b => b == 0))
            break;
        size_t checksum;
        foreach (i, b; header)
            checksum += i >= 148 && i < 156 ? 32 : b;
        if (checksum != octal(header[148 .. 156]))
            fail("E_PACKAGE", "invalid tar header checksum");
        auto name = field(header[0 .. 100]);
        auto prefix = field(header[345 .. 500]);
        if (prefix.length)
            name = prefix ~ "/" ~ name;
        auto size = octal(header[124 .. 136]);
        if (size > bytes.length - offset)
            fail("E_PACKAGE", "truncated tar entry");
        auto data = bytes[offset .. offset + size];
        auto padded = (size + 511) / 512 * 512;
        if (padded > bytes.length - offset)
            fail("E_PACKAGE", "truncated tar padding");
        offset += padded;
        auto type = header[156];
        if (type == 'L')
        {
            nextName = field(data).stripRight;
            continue;
        }
        if (type == 'x' || type == 'g')
        {
            foreach (line; (cast(string) data).splitLines)
            {
                auto pos = line.indexOf(" path=");
                if (pos >= 0)
                    paxName = line[cast(size_t) pos + 6 .. $];
            }
            continue;
        }
        if (nextName.length)
        {
            name = nextName;
            nextName = "";
        }
        if (paxName.length)
        {
            name = paxName;
            paxName = "";
        }
        auto path = safePath(root, name);
        if (type == '5')
            mkdirRecurse(path);
        else if (type == '0' || type == 0)
        {
            atomicWrite(path, data);
            setExecutable(path, (octal(header[100 .. 108]) & 73) != 0);
        }
        else
            fail("E_PACKAGE", "unsupported tar entry type for " ~ name);
    }
    if (!offset)
        fail("E_PACKAGE", "unrecognized archive format");
}

import std.algorithm;
