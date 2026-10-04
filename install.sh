git submodule update --init --recursive
dub build -c rattbuild --compiler=ldc2
./build/rattbuild build                 # build the shared runtime and all CLIs
dub test --compiler=ldc2
./build/rattsc --test tests/script
./tests/integration/run.sh              # also needs cmake, ninja, make, meson
sh tools/check.sh                       # pinned formatter, linter, unit/golden tests
