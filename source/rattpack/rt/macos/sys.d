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

    ProcessResult runSandboxed(string[] argv, string cwd, string[] writable, string temporary)
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
        return runProcess(command ~ argv, cwd, [
            "TMPDIR": temporary,
            "PYTHONDONTWRITEBYTECODE": "1"
        ]);
    }
}
