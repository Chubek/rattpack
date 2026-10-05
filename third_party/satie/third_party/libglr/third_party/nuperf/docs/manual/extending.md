# Extending

NuPERF extensions are plugin descriptors.

- Methods implement `nuperf_method_t`.
- Targets implement `nuperf_target_t`.
- Register plugins during initialization.
- Keep C API exception-free.
