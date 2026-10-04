module apps.ratt_language_server.main;

import rattpack.lsp.server : serve;
import std.stdio : stdin, stdout, stderr, writeln;

int main(string[] args)
{
    if (args.length == 2 && (args[1] == "--help" || args[1] == "-h"))
    {
        writeln(
                "Usage: ratt-language-server [--stdio]\nStatic Rattscript language services over LSP/JSON-RPC.");
        return 0;
    }
    if (args.length == 2 && args[1] == "--version")
    {
        writeln("ratt-language-server 0.1.0");
        return 0;
    }
    if (args.length > 2 || (args.length == 2 && args[1] != "--stdio"))
    {
        stderr.writeln("Usage: ratt-language-server [--stdio]");
        return 2;
    }
    return serve(stdin, stdout, stderr);
}
