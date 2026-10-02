#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
dub build -c rattbuild --compiler="${DC:-ldc2}"
dub build -c rattpkg --compiler="${DC:-ldc2}"
dub build -c rattsc --compiler="${DC:-ldc2}"
sh tools/build-plugins.sh
python3 tests/integration/run.py
