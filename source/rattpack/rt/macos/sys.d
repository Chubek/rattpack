module rattpack.rt.macos.sys;

version (OSX)
{
    public import rattpack.rt.common;
    import std.process : environment;
    import std.path : buildPath;
    import core.sys.posix.dlfcn;
    import std.string : toStringz, fromStringz;
    import std.parallelism : totalCPUs;

    enum executableSuffix = "";
    enum sharedSuffix = ".dylib";
    enum staticSuffix = ".a";
    enum backendName = "macos";
    string configHome()
    {
        return environment.get("XDG_CONFIG_HOME",
                buildPath(environment.get("HOME", "."), ".config"));
    }

    string cacheHome()
    {
        return environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "."), ".cache"));
    }

    string userName()
    {
        return environment.get("USER", "unknown");
    }

    size_t cpuCount()
    {
        return totalCPUs;
    }

    string linkTarget(string path)
    {
        import std.file : readLink;

        return readLink(path);
    }

    bool executableFile(string path)
    {
        import std.file : getAttributes;

        return (getAttributes(path) & 73) != 0;
    }

    void setExecutable(string path, bool executable)
    {
        import std.file : getAttributes, setAttributes;

        auto mode = getAttributes(path);
        setAttributes(path, executable ? mode | 73 : mode & ~73);
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
        return result;
    }

    string shellQuote(string value) @safe
    {
        import std.string : replace;

        return "'" ~ value.replace("'", "'\"'\"'") ~ "'";
    }

    void* openLibrary(string path)
    {
        return dlopen(path.toStringz, RTLD_NOW | RTLD_LOCAL);
    }

    void* librarySymbol(void* library, string name)
    {
        return dlsym(library, name.toStringz);
    }

    void closeLibrary(void* library)
    {
        if (library !is null)
            dlclose(library);
    }

    string libraryError()
    {
        auto error = dlerror();
        return error is null ? "unknown loader error" : error.fromStringz.idup;
    }

    bool mapRegion(string path, bool writable, out void* address, out size_t extent,
            out void* backing, char* error, size_t errorSize) @trusted
    {
        import core.sys.posix.sys.mman;
        import core.sys.posix.sys.uio;
        import core.sys.posix.fcntl;
        import core.sys.posix.unistd;
        import core.stdc.stdio : SEEK_END, snprintf;
        import core.stdc.errno : errno;
        import std.string : toStringz;

        address = null;
        extent = 0;
        backing = null;
        auto descriptor = open(toStringz(path), writable ? O_RDWR : O_RDONLY, 0);
        if (descriptor < 0)
        {
            describeErrno(error, errorSize, "cannot open");
            return false;
        }
        scope (exit)
            close(descriptor);
        auto size = lseek(descriptor, 0, SEEK_END);
        if (size < 0)
        {
            describeErrno(error, errorSize, "cannot size");
            return false;
        }
        extent = cast(size_t) size;
        // An empty file cannot be mapped; represent it as an empty view.
        if (extent == 0)
            return true;
        int protection = PROT_READ | (writable ? PROT_WRITE : 0);
        auto mapped = mmap(null, extent, protection, MAP_PRIVATE, descriptor, 0);
        if (mapped == MAP_FAILED)
        {
            describeErrno(error, errorSize, "cannot map");
            extent = 0;
            return false;
        }
        address = mapped;
        return true;
    }

    void unmapRegion(void* address, void* backing, size_t extent) @trusted
    {
        import core.sys.posix.sys.mman;

        if (address !is null && extent)
            munmap(address, extent);
    }

    private void describeErrno(char* error, size_t errorSize,
            const(char)* label) @trusted
    {
        extern (C) void ratt_describe_errno(int code, char* message, size_t capacity);

        import core.stdc.errno : errno;

        char[256] reason;
        ratt_describe_errno(errno, reason.ptr, reason.length);
        snprintf(error, errorSize, "%s: %s", label, reason.ptr);
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
        import std.json : JSONValue;

        auto program = locateProgram("sandbox-exec");
        string[] command;
        if (program.length)
        {
            auto profile = "(version 1)(allow default)(deny file-write*)";
            foreach (directory; writable ~ [temporary])
                profile ~= "(allow file-write* (subpath " ~ JSONValue(directory).toString ~ "))";
            command = [program, "-p", profile];
        }
        env = env.dup;
        env["TMPDIR"] = temporary;
        env["PYTHONDONTWRITEBYTECODE"] = "1";
        return runProcess(command ~ argv, cwd, env, false);
    }
}
