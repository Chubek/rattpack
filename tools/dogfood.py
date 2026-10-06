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


def cxx_compiler():
    return os.environ.get("CXX") or ("clang++" if macos else "c++")


def cxx_runtime_flags():
    """Link flags naming the C++ runtime the plugin needs at dlopen time.

    openaipp is a C++ header-only library, so the shared object references
    libstdc++ or libc++ symbols. Without a recorded dependency the loader
    cannot resolve them when the plugin is opened.
    """
    if windows:
        return []
    if macos:
        return ["-L-lc++"]
    for candidate in ("libstdc++.so.6", "libc++.so.1"):
        probe = subprocess.run([cxx_compiler(), "-print-file-name=" + candidate],
                               cwd=root, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
        name = probe.stdout.strip()
        if name and name != candidate and Path(name).exists():
            # -L-lNAME passes -lNAME to the linker; strip the lib prefix and
            # the shared-object suffix to recover the linker's name.
            stem = candidate.split(".so")[0]
            return ["-L-l" + (stem[3:] if stem.startswith("lib") else stem)]
    raise SystemExit("cannot locate the C++ runtime; set CXX to a working compiler")


def openai_assist_bridge():
    """Compile the openaipp C ABI bridge for the openai-assist plugin.

    The bridge is C++20 and is linked only into that plugin, so the shared
    runtime does not require a C++ toolchain. HTTPS support is enabled when
    OpenSSL headers are available; the helper then reports plain HTTP only.
    """
    third_party = root / "third_party/openaipp"
    source = root / "plugins/openai-assist/bridge.cpp"
    objects = root / "build/openai-assist"
    objects.mkdir(parents=True, exist_ok=True)
    archive = objects / ("rattsopenai.lib" if windows else "rattsopenai.a")
    defines = []
    extra = []
    if not windows:
        probe = subprocess.run([cxx_compiler(), "-E", "-x", "c++", "-"],
                               input=b"#include <openssl/ssl.h>\n", cwd=root,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode == 0:
            defines.append("-DCPPHTTPLIB_OPENSSL_SUPPORT")
            extra += ["-lssl", "-lcrypto"]
        else:
            print("openai-assist: OpenSSL headers not found; building without HTTPS",
                  file=sys.stderr)
    command = [cxx_compiler(), "-std=c++20", "-O2", "-fPIC", "-c", str(source),
               "-o", str(objects / "bridge.o"),
               "-I" + str(third_party / "include"),
               "-I" + str(third_party / "third_party"),
               "-I" + str(third_party / "third_party/cpp-httplib")] + defines
    run(command)
    if archive.exists():
        archive.unlink()
    if windows:
        run(["lib", "/nologo", "/out:" + str(archive), str(objects / "bridge.o")])
    else:
        run(["ar", "rcs", str(archive), str(objects / "bridge.o")])
    return str(archive)


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
    openai_bridge = openai_assist_bridge()
    for plugin in ("cmake", "gnumake", "ninja", "meson", "opencode-assist", "openai-assist"):
        # The OpenAI plugin keeps its C ABI declarations beside it, so both
        # modules are compiled as one unit and the bridge is linked in.
        sources = ["plugins/" + plugin + "/plugin.d"]
        extra = []
        if plugin == "openai-assist":
            sources.append("plugins/openai-assist/openai.d")
            extra.append(openai_bridge)
            extra += cxx_runtime_flags()
        run([compiler] + sources + imports
            + compiler_flags(shared=True, plugin=True) + extra
            + ["-od=" + str(directory), "-of=" + str(directory / (plugin + extension))])
else:
    raise SystemExit("usage: dogfood.py [--compiler DC] library | app NAME | plugins")
