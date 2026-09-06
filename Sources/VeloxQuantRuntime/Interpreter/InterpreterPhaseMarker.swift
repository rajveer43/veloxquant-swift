#if os(macOS)

/// `PythonEnvironment` — interpreter resolution (`autoDetect()`/`validate(interpreterPath:)`)
/// ported verbatim from Studio's `PythonEnvironmentService`. Lands in Phase 3.
enum InterpreterPhaseMarker {}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
