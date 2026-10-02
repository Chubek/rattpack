module rattpack.rt.posix.sys;

version (Posix)
{
    version (OSX)
    {
    }
    else
    {
        public import rattpack.rt.common;
        import std.process : environment;
        import std.path : buildPath;
        import core.sys.posix.dlfcn;
        import std.string : toStringz, fromStringz;
        import std.parallelism : totalCPUs;

        enum executableSuffix = "";
        enum sharedSuffix = ".so";
        enum staticSuffix = ".a";
        enum backendName = "posix";
        string configHome()
        {
            return environment.get("XDG_CONFIG_HOME",
                    buildPath(environment.get("HOME", "."), ".config"));
        }

        string cacheHome()
        {
            return environment.get("XDG_CACHE_HOME",
                    buildPath(environment.get("HOME", "."), ".cache"));
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
            static int available;
            auto program = locateProgram("bwrap");
            if (!available)
            {
                available = -1;
                if (program.length && runProcess([
                    program, "--ro-bind", "/", "/", "--proc", "/proc", "--dev",
                    "/dev", "/usr/bin/true"
                ]).status == 0)
                    available = 1;
            }
            string[] command;
            if (available == 1)
            {
                command = [
                    program, "--die-with-parent", "--ro-bind", "/", "/",
                    "--proc", "/proc", "--dev", "/dev"
                ];
                foreach (directory; writable)
                    command ~= ["--bind", directory, directory];
                command ~= [
                    "--bind", temporary, temporary, "--chdir", cwd, "--"
                ];
            }
            return runProcess(command ~ argv, cwd, [
                "TMPDIR": temporary,
                "PYTHONDONTWRITEBYTECODE": "1"
            ]);
        }
    }
}
