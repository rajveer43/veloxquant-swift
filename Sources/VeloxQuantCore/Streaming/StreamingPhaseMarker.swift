/// `chatStream()`'s `AsyncThrowingStream<ChatChunk, Error>` SSE parsing — keepalive-comment
/// skipping, `[DONE]` sentinel handling, and the usage-only final-frame case. Lands in Phase 1.
enum StreamingPhaseMarker {}
