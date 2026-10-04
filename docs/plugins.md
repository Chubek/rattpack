# Native plugins

Include `rattpack.plugin.abi` and link against the host's `librattpack` and shared
D runtime. Export this symbol with a stable, unmangled name:

```d
private RattPluginV1 plugin;

pragma(mangle, "rattpack_plugin_entry")
export extern(D) RattPluginV1* rattpack_plugin_entry()
{
    plugin = RattPluginV1.init;
    plugin.name = "my-exporter";
    plugin.kind = PluginKind.exporter;
    plugin.exportGraph = &exportGraph;
    return &plugin;
}
```

An exporter callback receives canonical DAG JSON, the destination directory,
and the absolute host executable path. It returns zero for success, or an error
string and nonzero status. Use `Graph.fromJSON` to validate the DAG; never load or
evaluate a Rattspec in an exporter.

Fetcher callbacks receive a source URL and destination directory. Toolchain
callbacks discover a compiler for a language. Stdlib callbacks register native
modules/functions with an `Evaluator`; mark side-effecting functions effectful
so construction-phase checks apply through aliases and helper functions.

The loader validates structure size, ABI major, compiler family and D major,
and the selected capability. First-party examples are in `plugins/`. Vtable
evolution is append-only: append fields and bump `minor`, never reorder or remove
existing fields. Keep the plugin loaded while any callback or registered native
function can still be referenced.

`plugins/opencode-assist/` is a stdlib plugin registering an `opencode` module
with one effectful `generate` function. It is loaded by `rattspec assist` (see
the manual, chapter 4) rather than by a build graph: the plugin speaks to
OpenCode V2 over the `opencode api` CLI, so the CLI's service discovery and
authentication apply, and marks the function effectful so it cannot be reached
during graph construction.
