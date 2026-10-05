#!/usr/bin/env python3
"""Stage authored manpages without requiring a roff formatter."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build")
    available = sorted(path.name for path in (ROOT / "man").glob("*.1"))
    parser.add_argument("pages", nargs="*", help="section 1 filenames; default: all pages")
    args = parser.parse_args()
    pages = args.pages or available
    for page in pages:
        if page not in available:
            parser.error("unknown manpage: " + page)
    destination = args.build_dir / "man/man1"
    destination.mkdir(parents=True, exist_ok=True)
    for page in pages:
        shutil.copy2(ROOT / "man" / page, destination / page)


if __name__ == "__main__":
    main()
