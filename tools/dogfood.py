#!/usr/bin/env python3
"""Bootstrap the library, then compile application entry points directly."""
import os
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
compiler = os.environ.get("DC", "ldc2")
arguments = sys.argv[1:]
if arguments and arguments[0] == "--compiler":
    compiler = arguments[1]
    arguments = arguments[2:]
windows = sys.platform == "win32"
macos = sys.platform == "darwin"
suffix = ".exe" if windows else ""
runtime = "rattpack.dll" if windows else "librattpack.dylib" if macos else "librattpack.so"


def compiler_flags(shared=False, plugin=False):
    flags = ["-preview=dip1000"]
    if "ldc" in Path(compiler).name:
        flags += ["-link-defaultlib-shared"]
        if shared and not windows:
            flags += ["-relocation-model=pic"]
    elif not windows:
        flags += ["-defaultlib=libphobos2.dylib" if macos else "-defaultlib=libphobos2.so"]
        if shared:
            flags += ["-fPIC"]
    if shared:
        flags += ["-shared"]
    if windows:
        flags += ["-L/LIBPATH:" + str(root / "build"), str(root / "build/rattpack.lib")]
    else:
        origin = "@loader_path" if macos else "$ORIGIN"
        flags += ["-L-L" + str(root / "build"), "-L-lrattpack", "-L-rpath=" + origin + ("/.." if plugin else "")]
    return flags


def run(argv):
    subprocess.run(argv, cwd=root, check=True)


def import_flags():
    # DUB's description metadata must stay within the writable build tree.
    description = json.loads(subprocess.check_output(
        ["dub", "describe", "-c", "rattbuild", "--compiler=" + compiler,
         "--dest=" + str(root / "build")], cwd=root, text=True))
    flags = []
    for package in description["packages"]:
        for field, prefix in (("importPaths", "-I"), ("stringImportPaths", "-J")):
            for path in package.get(field, []):
                flag = prefix + str(Path(package["path"]) / path)
                if flag not in flags:
                    flags.append(flag)
    return flags


if not arguments:
    raise SystemExit("usage: dogfood.py [--compiler DC] library | app NAME | plugins")
if arguments[0] == "library":
    # The active host maps this inode. Preserve it while DUB publishes a new
    # library, avoiding in-place truncation of a running shared object.
    library = root / "build" / runtime
    backup = library.with_name(library.stem + ".bootstrap" + library.suffix)
    if library.exists():
        os.replace(library, backup)
    try:
        run(["dub", "build", "-c", "bootstrap-runtime", "--compiler=" + compiler])
    except Exception:
        if backup.exists():
            os.replace(backup, library)
        raise
    finally:
        if library.exists() and backup.exists():
            try:
                backup.unlink()
            except PermissionError:
                # Windows retains mapped images until the active host exits.
                if not windows:
                    raise
elif arguments[0] == "app":
    name = arguments[1]
    temporary = root / ("build/" + name + ".new" + suffix)
    objects = root / "build/objects" / name
    objects.mkdir(parents=True, exist_ok=True)
    run([compiler, "source/apps/" + name + "/main.d"] + import_flags()
        + compiler_flags() + ["-od=" + str(objects), "-of=" + str(temporary)])
    destination = root / ("build/" + name + suffix)
    if windows and destination.exists():
        backup = destination.with_name(name + ".bootstrap" + suffix)
        os.replace(destination, backup)
        try:
            os.replace(temporary, destination)
        except Exception:
            os.replace(backup, destination)
            raise
        try:
            backup.unlink()
        except PermissionError:
            pass
    else:
        os.replace(temporary, destination)
elif arguments[0] == "plugins":
    imports = import_flags()
    directory = root / "build/plugins"
    directory.mkdir(parents=True, exist_ok=True)
    extension = ".dll" if windows else ".dylib" if macos else ".so"
    for plugin in ("cmake", "gnumake", "ninja", "meson", "opencode-assist"):
        run([compiler, "plugins/" + plugin + "/plugin.d"] + imports
            + compiler_flags(shared=True, plugin=True)
            + ["-od=" + str(directory), "-of=" + str(directory / (plugin + extension))])
else:
    raise SystemExit("usage: dogfood.py [--compiler DC] library | app NAME | plugins")
