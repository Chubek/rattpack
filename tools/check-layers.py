#!/usr/bin/env python3
"""Lint repository import boundaries (including function-local D imports)."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FOUNDATION = {"rt", "native", "content", "diagnostic", "serialization"}
ALLOWED = {
    "rt": {"rt", "diagnostic"},
    "native": {"native", "diagnostic"},
    "content": FOUNDATION,
    "diagnostic": {"diagnostic"},
    "serialization": {"serialization"},
    "script": FOUNDATION | {"script"},
    "config": FOUNDATION | {"script", "config", "stdlib"},
    "stdlib": FOUNDATION | {"script", "config", "stdlib"},
    "graph": FOUNDATION | {"graph", "script", "config", "stdlib"},
    "pkg": FOUNDATION | {"pkg", "script", "config", "stdlib"},
    "spec": FOUNDATION | {"spec", "script", "config", "stdlib", "graph", "pkg"},
    "plugin": FOUNDATION | {"plugin", "graph", "script"},
}


def violations(path, source):
    component = path.relative_to(ROOT / "source/rattpack").parts[0].split(".")[0]
    # This is a source lint, not a complete D parser. Check normal import
    # statements at any indentation, including scoped and public imports.
    for match in re.finditer(r"^\s*(?:public\s+|private\s+|static\s+)?import\s+([^;]+);", source, re.M):
        for module in re.findall(r"\brattpack\.[\w.]+", match.group(1).split(":")[0]):
            dependency = module.split(".")[1]
            if component != "cli" and dependency not in ALLOWED.get(component, set()):
                yield f"{path.relative_to(ROOT)}: forbidden import {module} from {component}"
            if component == "spec" and dependency == "pkg" and module != "rattpack.pkg.lockfile":
                yield f"{path.relative_to(ROOT)}: specs may only read package lockfiles"
    if component != "rt" and re.search(r"\bversion\s*\(\s*(Windows|OSX|Posix|linux)\s*\)", source):
        yield f"{path.relative_to(ROOT)}: platform selection belongs in rt backends"


def main():
    errors = []
    for path in sorted((ROOT / "source/rattpack").rglob("*.d")):
        # Remove comments before checking; strings are retained because this
        # lint examines import statements anchored at line beginnings.
        source = re.sub(r"/\*.*?\*/|//[^\n]*", "", path.read_text(), flags=re.S)
        errors.extend(violations(path, source))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Rattpack layer boundaries passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
