# C API

Primary header: `include/nuperf/nuperf-api.h`

Core flow:

1. `nuperf_init()`
2. `nuperf_keyset_create()` + key insertion
3. `nuperf_table_create()`
4. `nuperf_table_set_keyset()`
5. `nuperf_table_build()`
6. `nuperf_table_emit_*()`
7. destroy handles + `nuperf_shutdown()`
