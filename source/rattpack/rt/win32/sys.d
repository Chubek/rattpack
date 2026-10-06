module rattpack.rt.win32.sys;

version (Windows)
{
    public import rattpack.rt.common;
    import std.process : environment;
    import std.path : buildPath;
    import core.sys.windows.windows;
    import std.utf : toUTF16z;
    import std.parallelism : totalCPUs;

    enum executableSuffix = ".exe";
    enum sharedSuffix = ".dll";
    enum staticSuffix = ".lib";
    enum backendName = "win32";
    string configHome()
    {
        return environment.get("APPDATA", ".");
    }

    string cacheHome()
    {
        return environment.get("LOCALAPPDATA", configHome);
    }

    string userName()
    {
        return environment.get("USERNAME", "unknown");
    }

    size_t cpuCount()
    {
        return totalCPUs;
    }

    string linkTarget(string path)
    {
        import core.sys.windows.winioctl : FSCTL_GET_REPARSE_POINT;

        auto handle = CreateFileW(path.toUTF16z, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
                OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
        if (handle == INVALID_HANDLE_VALUE)
            throw new Exception("cannot read link target");
        scope (exit)
            CloseHandle(handle);
        // Use the stored target, not the final absolute path: moving a package
        // from its extraction directory into the cache must preserve its hash.
        align(8) ubyte[MAXIMUM_REPARSE_DATA_BUFFER_SIZE] storage;
        DWORD received;
        if (!DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, null, 0,
                storage.ptr, cast(DWORD) storage.length, &received, null)
                || received < REPARSE_DATA_BUFFER_HEADER_SIZE)
            throw new Exception("cannot read link target");
        auto data = cast(REPARSE_DATA_BUFFER*) storage.ptr;
        wchar* buffer;
        size_t offset, length;
        if (data.ReparseTag == IO_REPARSE_TAG_SYMLINK)
        {
            auto link = &data.SymbolicLinkReparseBuffer;
            buffer = link.PathBuffer;
            offset = link.PrintNameLength ? link.PrintNameOffset : link.SubstituteNameOffset;
            length = link.PrintNameLength ? link.PrintNameLength : link.SubstituteNameLength;
        }
        else if (data.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT)
        {
            auto link = &data.MountPointReparseBuffer;
            buffer = link.PathBuffer;
            offset = link.PrintNameLength ? link.PrintNameOffset : link.SubstituteNameOffset;
            length = link.PrintNameLength ? link.PrintNameLength : link.SubstituteNameLength;
        }
        else
            throw new Exception("unsupported reparse point");
        auto base = cast(size_t)(cast(ubyte*) buffer - storage.ptr);
        if (offset % wchar.sizeof || length % wchar.sizeof || base + offset + length > received)
            throw new Exception("invalid link target");
        import std.utf : toUTF8;

        return buffer[offset / wchar.sizeof .. (offset + length) / wchar.sizeof].toUTF8;
    }

    bool executableFile(string path)
    {
        return false;
    }

    void setExecutable(string path, bool executable)
    {
    }

    string locateProgram(string name)
    {
        return findProgram(name, environment.get("PATH", ""));
    }

    string[string] buildProcessEnvironment()
    {
        string[string] result = [
            "PATH": environment.get("PATH", ""), "LANG": "C", "LC_ALL": "C",
            "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"
        ];
        foreach (key; ["SystemRoot", "WINDIR", "COMSPEC", "PATHEXT"])
            if (auto value = environment.get(key, ""))
                result[key] = value;
        return result;
    }

    string shellQuote(string value) @safe
    {
        import std.process : escapeWindowsArgument;

        return escapeWindowsArgument(value);
    }

    void* openLibrary(string path)
    {
        return cast(void*) LoadLibraryW(path.toUTF16z);
    }

    void* librarySymbol(void* library, string name)
    {
        import std.string : toStringz;

        return cast(void*) GetProcAddress(cast(HMODULE) library, name.toStringz);
    }

    void closeLibrary(void* library)
    {
        if (library !is null)
            FreeLibrary(cast(HMODULE) library);
    }

    string libraryError()
    {
        import std.conv : to;

        return "Win32 loader error " ~ GetLastError().to!string;
    }

    bool mapRegion(string path, bool writable, out void* address, out size_t extent,
            out void* backing, char* error, size_t errorSize) @trusted
    {
        import core.sys.windows.windows;
        import std.utf : toUTF16z;
        import std.conv : to;
        import core.stdc.stdio : snprintf;

        address = null;
        extent = 0;
        backing = null;
        DWORD access = writable ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ;
        auto handle = CreateFileW(path.toUTF16z, access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (handle == INVALID_HANDLE_VALUE)
        {
            snprintf(error, errorSize, "cannot open: error %d",
                    cast(int) GetLastError());
            return false;
        }
        scope (exit)
            CloseHandle(handle);
        LARGE_INTEGER size;
        if (!GetFileSizeEx(handle, &size) || size.QuadPart < 0)
        {
            snprintf(error, errorSize, "cannot size: error %d",
                    cast(int) GetLastError());
            return false;
        }
        extent = cast(size_t) size.QuadPart;
        // An empty file has no section object; represent it as an empty view.
        if (extent == 0)
            return true;
        DWORD protection = writable ? (PAGE_READWRITE) : PAGE_READONLY;
        auto mapping = CreateFileMappingW(handle, null, protection, 0, 0, null);
        if (mapping is null)
        {
            snprintf(error, errorSize, "cannot create mapping: error %d",
                    cast(int) GetLastError());
            extent = 0;
            return false;
        }
        DWORD viewAccess = writable ? FILE_MAP_WRITE : FILE_MAP_READ;
        auto view = MapViewOfFile(mapping, viewAccess, 0, 0, extent);
        if (view is null)
        {
            snprintf(error, errorSize, "cannot map view: error %d",
                    cast(int) GetLastError());
            CloseHandle(mapping);
            extent = 0;
            return false;
        }
        address = view;
        // Win32 requires the section to stay open until its view is released.
        backing = cast(void*) mapping;
        return true;
    }

    void unmapRegion(void* address, void* backing, size_t extent) @trusted
    {
        import core.sys.windows.windows;

        if (address !is null && extent)
            UnmapViewOfFile(address);
        if (backing !is null)
            CloseHandle(cast(HANDLE) backing);
    }

    ProcessResult runHermetic(string[] argv, string cwd, string[] writable,
            string temporary, string[] readable, string[string] env)
    {
        import rattpack.diagnostic : fail;

        fail("E_HERMETIC", "strict subprocess isolation is unavailable on this backend");
        return ProcessResult.init;
    }

    ProcessResult runSandboxed(string[] argv, string cwd, string[] writable,
            string temporary, string[string] env = null)
    {
        env = env.dup;
        env["TEMP"] = temporary;
        env["TMP"] = temporary;
        return runProcess(argv, cwd, env, false);
    }
}
