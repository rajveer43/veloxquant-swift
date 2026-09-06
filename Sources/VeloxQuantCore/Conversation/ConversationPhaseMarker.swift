/// `Conversation` — an `actor` wrapping `history: [Message]` with Go's stricter contract
/// (a failed turn leaves `history` unchanged). Lands in Phase 4.
enum ConversationPhaseMarker {}
