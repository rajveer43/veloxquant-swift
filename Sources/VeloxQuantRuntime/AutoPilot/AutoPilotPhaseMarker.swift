#if os(macOS)

/// `AutoPilot` — shell-out-based recommend/auto-config orchestration (`tryStart()`/`start()`),
/// matching TS's and VeloxQuant-Studio's own independently-arrived-at architecture.
/// Lands in Phase 4.
enum AutoPilotPhaseMarker {}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
