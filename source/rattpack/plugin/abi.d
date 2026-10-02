module rattpack.plugin.abi;

import rattpack.script.evaluator : Evaluator;

enum PluginKind : uint
{
    exporter,
    fetcher,
    toolchain,
    stdlib
}

version (LDC)
    enum compilerFamily = "ldc";
else
    enum compilerFamily = "dmd";
enum uint compilerMajor = __VERSION__ / 1000;

// V1 layout is append-only. Functions use the D ABI and the host's shared
// runtime; never reinterpret a C ABI plugin as a Rattpack plugin.
struct RattPluginV1
{
    uint structSize = RattPluginV1.sizeof;
    uint major = 1;
    uint minor = 0;
    string compiler = compilerFamily;
    uint compilerVersion = compilerMajor;
    PluginKind kind;
    string name;
    extern (D) int function(string dagJSON, string destination, string host, out string error) exportGraph;
    extern (D) int function(string url, string destination, out string error) fetchPackage;
    extern (D) string function(string language) discoverToolchain;
    extern (D) void function(Evaluator evaluator) registerModules;
}

alias PluginEntry = extern (D) RattPluginV1* function();
