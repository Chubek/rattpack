# Installation

## Configure

```bash
cmake -S . -B build \
  -DNUPERF_BUILD_CLI=ON \
  -DNUPERF_BUILD_DOCS=ON \
  -DNUPERF_INSTALL_DOCS=ON \
  -DNUPERF_INSTALL_STDMETH=ON \
  -DNUPERF_INSTALL_STDDEF=ON
```

## Build

```bash
cmake --build build
cmake --build build --target docs
```

## Install

```bash
cmake --install build --prefix /usr/local
```

Installed CMake package files:

- `lib/cmake/nuperf/nuperfConfig.cmake`
- `lib/cmake/nuperf/nuperfConfigVersion.cmake`
- `lib/cmake/nuperf/nuperfTargets.cmake`
