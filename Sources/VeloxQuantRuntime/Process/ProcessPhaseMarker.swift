#if os(macOS)

/// `VeloxQuantProcess` — full `serve` process lifecycle: launch, the priming-request-vs-
/// `VELOXQUANT_READY`-handshake readiness race, and `SIGINT`-first shutdown. Lands in Phase 5.
enum ProcessPhaseMarker {}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
