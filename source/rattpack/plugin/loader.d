module rattpack.plugin.loader;

import rattpack.plugin.abi;
import rattpack.rt.sys;
import rattpack.diagnostic;

class Plugin
{
    private void* library;
    RattPluginV1* api;
    this(string path)
    {
        library = openLibrary(path);
        if (library is null)
            fail("E_PLUGIN_ABI", "cannot load plugin: " ~ libraryError);
        auto entry = cast(PluginEntry) librarySymbol(library, "rattpack_plugin_entry");
        if (entry is null)
        {
            close;
            fail("E_PLUGIN_ABI", "plugin has no rattpack_plugin_entry");
        }
        api = entry();
        try
        {
            validatePlugin(api);
        }
        catch (Exception e)
        {
            close;
            throw e;
        }
    }

    void close()
    {
        if (library !is null)
        {
            closeLibrary(library);
            library = null;
            api = null;
        }
    }
}

void validatePlugin(RattPluginV1* api)
{
    if (api is null || api.structSize < RattPluginV1.sizeof || api.major != 1
            || api.compiler != compilerFamily || api.compilerVersion != compilerMajor)
        fail("E_PLUGIN_ABI", "incompatible plugin ABI or D compiler major version");
    if (!api.name.length)
        fail("E_PLUGIN_ABI", "plugin name is empty");
    final switch (api.kind)
    {
    case PluginKind.exporter:
        if (api.exportGraph is null)
            fail("E_PLUGIN_ABI",
                    "exporter has no export callback");
        break;
    case PluginKind.fetcher:
        if (api.fetchPackage is null)
            fail("E_PLUGIN_ABI",
                    "fetcher has no fetch callback");
        break;
    case PluginKind.toolchain:
        if (api.discoverToolchain is null)
            fail("E_PLUGIN_ABI",
                    "toolchain has no discovery callback");
        break;
    case PluginKind.stdlib:
        if (api.registerModules is null)
            fail("E_PLUGIN_ABI",
                    "stdlib has no registration callback");
        break;
    }
}
