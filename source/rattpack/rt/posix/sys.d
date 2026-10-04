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
        import std.string : toStringz, fromStringz, startsWith;
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

        string[string] buildProcessEnvironment()
        {
            string[string] result = [
                "PATH": environment.get("PATH", ""), "LANG": "C",
                "LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"
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

        ProcessResult runHermetic(string[] argv, string cwd, string[] writable,
                string temporary, string[] readable, string[string] env)
        {
            import rattpack.diagnostic : fail;
            import std.file : exists, mkdirRecurse;
            import std.path : dirName;
            import std.conv : to;

            auto program = locateProgram("bwrap");
            if (!program.length)
                fail("E_HERMETIC", "strict subprocess isolation requires Bubblewrap");
            string[] command = [
                program, "--die-with-parent", "--unshare-all", "--new-session",
                "--tmpfs", "/"
            ];
            // These are the trusted system toolchain and runtime roots. The project
            // and user home are absent; only declared input files are mounted below.
            foreach (directory; ["/usr", "/bin", "/sbin", "/lib", "/lib64"])
                if (exists(directory))
                    command ~= ["--ro-bind", directory, directory];
            if (exists("/etc/ld.so.cache"))
                command ~= ["--ro-bind", "/etc/ld.so.cache", "/etc/ld.so.cache"];
            command ~= [
                "--proc", "/proc", "--dev", "/dev", "--bind", temporary, temporary
            ];
            foreach (i, directory; writable)
            {
                auto stage = buildPath(temporary, "outputs", i.to!string);
                mkdirRecurse(stage);
                command ~= ["--bind", stage, directory];
            }
            foreach (file; readable)
                command ~= ["--ro-bind", file, file];
            command ~= ["--dir", cwd, "--chdir", cwd, "--"];
            env = env.dup;
            env["HOME"] = temporary;
            env["XDG_CONFIG_HOME"] = buildPath(temporary, "config");
            env["XDG_CACHE_HOME"] = buildPath(temporary, "cache");
            env["TMPDIR"] = temporary;
            env["PYTHONDONTWRITEBYTECODE"] = "1";
            auto result = runProcess(command ~ argv, cwd, env, false);
            if (result.status && result.output.startsWith("bwrap:"))
                fail("E_HERMETIC", "strict subprocess isolation failed: " ~ result.output);
            return result;
        }

        ProcessResult runSandboxed(string[] argv, string cwd, string[] writable,
                string temporary, string[string] env = null)
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
            env = env.dup;
            env["TMPDIR"] = temporary;
            env["PYTHONDONTWRITEBYTECODE"] = "1";
            return runProcess(command ~ argv, cwd, env, false);
        }
    }
}
