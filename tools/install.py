#!/usr/bin/env python3
"""Build and install a relocatable Rattpack layout using only Python's stdlib."""
import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APPLICATIONS = ("rattbuild", "rattpkg", "rattsc", "rattspec", "ratt-language-server")
PLUGINS = ("cmake", "gnumake", "ninja", "meson", "opencode-assist")


def platform_names():
    if sys.platform == "win32":
        return ".exe", "rattpack.dll", ".dll"
    if sys.platform == "darwin":
        return "", "librattpack.dylib", ".dylib"
    return "", "librattpack.so", ".so"


def installation_plan(build, with_plugins=False):
    suffix, library, plugin_suffix = platform_names()
    plan = [(build / (app + suffix), Path("bin") / (app + suffix))
            for app in APPLICATIONS]
    plan.append((build / library, Path("bin") / library))
    if with_plugins:
        plan.extend((build / "plugins" / (name + plugin_suffix),
                     Path("bin/plugins") / (name + plugin_suffix)) for name in PLUGINS)
    # Install authored sources so prebuilt/custom build directories need no
    # separate documentation build. DUB and Rattspec also stage these in build/.
    plan.extend((ROOT / "man" / (app + ".1"), Path("share/man/man1") / (app + ".1"))
                for app in APPLICATIONS)
    for directory in ("profiles", "templates", "manual", "docs", "addons"):
        plan.extend((path, Path("share/rattpack") / path.relative_to(ROOT))
                    for path in sorted((ROOT / directory).rglob("*"))
                    if path.is_file() and "__pycache__" not in path.parts)
    plan.extend((ROOT / name, Path("share/rattpack") / name)
                for name in ("README.md", "LICENSE"))
    missing = [str(source) for source, _ in plan if not source.is_file()]
    if missing:
        raise ValueError("missing build products; use --build or build all CLIs first:\n"
                         + "\n".join(missing))
    return plan


def staged_prefix(prefix, destdir):
    prefix = prefix.expanduser().absolute()
    if destdir is None:
        return prefix
    # Strip the anchor for package staging, including Windows drive letters.
    return destdir.expanduser().absolute().joinpath(*prefix.parts[1:])


def install(plan, destination):
    # Validate all destination paths before copying anything.
    for _, relative in plan:
        target = destination / relative
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError(f"destination is not a regular file: {target}")
        parent = target.parent
        while not parent.exists():
            parent = parent.parent
        if not parent.is_dir():
            raise ValueError(f"destination parent is not a directory: {parent}")
    destination.mkdir(parents=True, exist_ok=True)
    # Prefix subdirectories may be symlinks or mounts on other filesystems.
    # Stage each file and its rollback backup beside its final destination.
    # os.replace preserves already mapped executables/libraries on POSIX.
    with ExitStack() as cleanup:
        directories = {}
        staged = []
        for source, relative in plan:
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.parent not in directories:
                directories[target.parent] = Path(cleanup.enter_context(
                    tempfile.TemporaryDirectory(prefix=".rattpack-install-", dir=target.parent)))
            staging = directories[target.parent]
            temporary = staging / target.name
            shutil.copy2(source, temporary)
            backup = staging / "backups" / target.name
            if target.exists():
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup)
            staged.append((temporary, target, backup))
        published = []
        try:
            for temporary, target, backup in staged:
                os.replace(temporary, target)
                published.append((target, backup))
        except OSError:
            for target, backup in reversed(published):
                if backup.exists():
                    os.replace(backup, target)
                else:
                    target.unlink()
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local",
                        help="install prefix (default: ~/.local); applications go in bin, manpages in share/man/man1")
    parser.add_argument("--destdir", type=Path, help="package staging root prepended to prefix")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build",
                        help="directory containing the applications, language server and shared runtime")
    parser.add_argument("--build", action="store_true", help="bootstrap all applications with DUB")
    parser.add_argument("--compiler", default=os.environ.get("DC", "ldc2"))
    parser.add_argument("--with-plugins", action="store_true", help="also install native exporter and assist plugins")
    parser.add_argument("--dry-run", action="store_true", help="print the validated copy plan without writing")
    args = parser.parse_args(argv)
    try:
        if args.build:
            if args.dry_run:
                raise ValueError("--build and --dry-run cannot be combined; preview an existing build")
            if args.build_dir.resolve() != (ROOT / "build").resolve():
                raise ValueError("--build requires the repository build directory")
            for app in APPLICATIONS:
                subprocess.run(["dub", "build", "-c", app, "--compiler=" + args.compiler],
                               cwd=ROOT, check=True)
            if args.with_plugins:
                subprocess.run([sys.executable, str(ROOT / "tools/dogfood.py"),
                                "--compiler", args.compiler, "plugins"], cwd=ROOT, check=True)
        plan = installation_plan(args.build_dir.resolve(), args.with_plugins)
        destination = staged_prefix(args.prefix, args.destdir)
        if args.dry_run:
            for source, relative in plan:
                print(f"{source} -> {destination / relative}")
            return 0
        install(plan, destination)
        print(f"Installed Rattpack in {destination}")
        print(f"Add {args.prefix.expanduser().absolute() / 'bin'} to PATH.")
        print("The matching D shared runtime and system libraries must be available.")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"install: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
