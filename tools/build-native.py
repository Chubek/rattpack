#!/usr/bin/env python3
"""Compile pinned native libraries with CMake on each supported backend."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
directory = root / "build/native-project"
# Keep the build-tree zlib copy current without touching the submodule. CMake's
# build command reconfigures when any CMakeLists changes; source changes need
# only compilation, rather than repeating libgit2's configure-time generation.
for source in (root / "third_party/zlib").rglob("*"):
    relative = source.relative_to(root / "third_party/zlib")
    if source.is_file() and ".git" not in relative.parts and source.name != "zconf.h":
        destination = directory / "zlib-source" / relative
        if not destination.exists() or destination.stat().st_mtime_ns != source.stat().st_mtime_ns:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
if not (directory / "CMakeCache.txt").exists():
    subprocess.run(["cmake", "-S", str(root / "tools/native"), "-B", str(directory),
                    "-DCMAKE_BUILD_TYPE=Release"], check=True)
subprocess.run(["cmake", "--build", str(directory), "--config", "Release",
                "--target", "rattnative", "--parallel", "4"], check=True)
