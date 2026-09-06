#if os(macOS)

/// One-shot CLI subcommand shell-out helpers (`recommend --json`, `auto-config --json`,
/// `methods --json`, `profile`, `precompute`, `benchmark`) and their pure argument-builder
/// functions. Lands starting Phase 3.
enum CLIPhaseMarker {}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
