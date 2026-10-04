"""Register the bundled clients with Sublime Text's LSP package."""
import sublime

try:
    from LSP.plugin import AbstractPlugin, register_plugin, unregister_plugin
except ImportError:
    # Syntax highlighting remains available when the optional LSP package is absent.
    AbstractPlugin = None


if AbstractPlugin is not None:
    class RattPlugin(AbstractPlugin):
        @classmethod
        def configuration(cls):
            filename = "LSP-" + cls.name() + ".sublime-settings"
            package = __package__.split(".")[0]
            return sublime.load_settings(filename), "Packages/" + package + "/" + filename

    class RattscriptPlugin(RattPlugin):
        @classmethod
        def name(cls):
            return "Rattscript"

    class RattspecPlugin(RattPlugin):
        @classmethod
        def name(cls):
            return "Rattspec"

    class RattpkgPlugin(RattPlugin):
        @classmethod
        def name(cls):
            return "Rattpkg"

    PLUGINS = (RattscriptPlugin, RattspecPlugin, RattpkgPlugin)
else:
    PLUGINS = ()


def plugin_loaded():
    for plugin in PLUGINS:
        register_plugin(plugin)


def plugin_unloaded():
    for plugin in PLUGINS:
        unregister_plugin(plugin)
