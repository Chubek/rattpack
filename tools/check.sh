#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
dc=${DC:-ldc2}
dub run dfmt@0.15.2 --compiler="$dc" -- -i source/ tests/unit/ plugins/
dub run dscanner@0.16.0-beta.5 --compiler="$dc" -- --styleCheck source/
dub test --compiler="$dc"
dub build -c rattsc --compiler="$dc"
./build/rattsc --test tests/script
dub build -c ratt-language-server --compiler="$dc"
python3 tests/addons/run.py
