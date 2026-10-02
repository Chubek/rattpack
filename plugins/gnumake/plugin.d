module rattpack_exporter_gnumake;
import rattpack.plugin.abi;
import rattpack.plugin.exporters;

private RattPluginV1 plugin;
pragma(mangle, "rattpack_plugin_entry") export extern (D) RattPluginV1* rattpack_plugin_entry()
{
    plugin = builtinExporter("gnumake");
    return &plugin;
}
