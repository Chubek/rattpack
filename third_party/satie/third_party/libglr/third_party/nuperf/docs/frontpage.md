# NuPERF - Perfect Hashing Library

## Overview

NuPERF is an extensible, multi-target, multi-algorithm perfect hashing software library.

### Key Features

- **Extensible Architecture**: Add custom algorithms via API
- **Multiple Algorithms**: PTHash, BBHash, FCH, BDZ
- **Multi-Target Support**: Generate code for C, C++, Python, Rust, and more
- **Embeddable**: C API with SWIG bindings
- **Lua Interface**: Define hash tables using Lua scripts

## Documentation

- [User Manual](manual/index.html)
- [API Reference](files.html)
- [Extending NuPERF](manual/extending.html)

## Quick Start
```lua
local nuperf = require("lnuperf")

local ht = nuperf.HashTable("Months")
ht:add_keys({"January", "February", "March"})
ht:set_method("BBHash")
ht:set_target("C")
ht:emit("months.h")

See the [examples](examples.html) directory for more usage patterns.
