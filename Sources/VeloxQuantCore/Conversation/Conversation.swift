import Foundation

/// Accumulates chat history across turns so callers don't build `[Message]` by hand each call.
///
/// Semantics are Go's `Conversation` (`veloxquant-go/conversation.go`), the stricter of the
/// sibling contracts (plan §3.7):
///
/// - `send(_:)` appends the prompt as a user message, sends the full history so far, and — only
///   if the request succeeds — records both the user message and the assistant's reply. **A
///   failed turn leaves `history` exactly as it was**, so a retried `send(_:)` starts from the
///   same state.
/// - `sendStream(_:)` records the turn only once the stream finishes without error. A stream
///   that throws, or that the consumer stops iterating early (break/cancellation), leaves
///   `history` unchanged.
///
/// Swift-idiom divergence from Go, deliberately: Go's `Conversation` is documented as "not
/// safe for concurrent use". This is an `actor`, and because actor methods are reentrant
/// across `await`, it additionally serializes turns: a second `send`/`sendStream` started while
/// one is in flight waits for the first to finish, so two overlapping turns can never both be
/// built on the same stale history (and one silently lost).
///
/// Unlike Go (which records only the reply text), the recorded assistant message keeps any
/// `toolCalls` the reply carried, so a later turn can answer them with `.tool(...)` messages.
public actor Conversation {
    /// The accumulated messages so far, oldest first (a value copy).
    public private(set) var history: [Message]

    /// The client this conversation sends through.
    public nonisolated let client: VeloxQuantClient
    /// The model every turn requests; `nil` falls back to `client.defaultModel`.
    public nonisolated let model: String?

    private var turnInFlight = false
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    /// Creates a conversation bound to `model` (Go's `NewConversation(model, system)`). A
    /// non-empty `system` seeds the history with an initial system prompt.
    public init(client: VeloxQuantClient, model: String? = nil, system: String? = nil) {
        self.client = client
        self.model = model
        if let system, !system.isEmpty {
            history = [.system(system)]
        } else {
            history = []
        }
    }

    /// Sends `prompt` as the next user turn and returns the reply, recording the turn only on
    /// success.
    public func send(_ prompt: String) async throws -> ChatResponse {
        await beginTurn()
        defer { endTurn(committing: nil) }

        let pending = history + [.user(prompt)]
        let response = try await client.chat(makeRequest(pending))
        let reply = Message.assistant(
            response.choice.message.content,
            toolCalls: response.choice.message.toolCalls
        )
        history = pending + [reply]
        return response
    }

    /// Streams the reply to `prompt` as the next user turn. The turn (user message + the
    /// concatenated streamed reply) is recorded only once the stream finishes without error.
    public nonisolated func sendStream(_ prompt: String) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.beginTurn()
                let pending = await self.history + [.user(prompt)]
                var text = ""
                do {
                    for try await chunk in self.client.chatStream(self.makeRequest(pending)) {
                        if let content = chunk.delta?.content {
                            text += content
                        }
                        continuation.yield(chunk)
                    }
                    // An abandoned stream ends its inner iteration without throwing; never
                    // record a partial reply as if it were the model's full turn.
                    try Task.checkCancellation()
                    await self.endTurn(committing: pending + [.assistant(text)])
                    continuation.finish()
                } catch {
                    await self.endTurn(committing: nil)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func makeRequest(_ messages: [Message]) -> ChatRequest {
        ChatRequest(messages: messages, model: model ?? client.defaultModel)
    }

    private func beginTurn() async {
        guard turnInFlight else {
            turnInFlight = true
            return
        }
        await withCheckedContinuation { waitingTurns.append($0) }
    }

    private func endTurn(committing newHistory: [Message]?) {
        if let newHistory {
            history = newHistory
        }
        if waitingTurns.isEmpty {
            turnInFlight = false
        } else {
            waitingTurns.removeFirst().resume()
        }
    }
}
