/// `MemoryEstimator` — pure, offline, closed-form KV-cache memory accounting. The one
/// deliberate exception to "never reimplement the Python engine," since it must work
/// instantly on every Apple platform including watchOS. Lands in Phase 2.
enum MemoryPhaseMarker {}
