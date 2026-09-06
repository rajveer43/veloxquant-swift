import Foundation

private struct ChunkChoice: Codable {
    let delta: Delta?
    let finishReason: FinishReason?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

/// One SSE-streamed chat completion chunk (investigation §1.5). `usage` is populated only on
/// the final usage-only frame (`object: "chat.completion"`, empty `choices: []`, populated
/// `usage`, sent when `stream_options.include_usage` is true) — every other chunk leaves it
/// `nil` rather than defaulting to a zeroed `Usage`, so a caller cannot mistake "not reported
/// yet" for "zero tokens." `id`/`delta`/`finishReason` are correspondingly optional so the
/// usage-only frame (which carries none of them meaningfully) doesn't need placeholder values.
public struct ChatChunk: Codable, Sendable, Equatable {
    public let id: String?
    public let delta: Delta?
    public let finishReason: FinishReason?
    public let usage: Usage?

    public init(id: String?, delta: Delta?, finishReason: FinishReason?, usage: Usage?) {
        self.id = id
        self.delta = delta
        self.finishReason = finishReason
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, choices, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage)

        let choices = try container.decode([ChunkChoice].self, forKey: .choices)
        if let firstChoice = choices.first {
            delta = firstChoice.delta
            finishReason = firstChoice.finishReason
        } else {
            // The usage-only final frame: empty choices array, populated usage.
            delta = nil
            finishReason = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(usage, forKey: .usage)
        if delta != nil || finishReason != nil {
            try container.encode([ChunkChoice(delta: delta, finishReason: finishReason)], forKey: .choices)
        } else {
            try container.encode([ChunkChoice](), forKey: .choices)
        }
    }
}

/// Incremental content within one `ChatChunk`.
public struct Delta: Codable, Sendable, Equatable {
    public let role: String?
    public let content: String?
    public let toolCalls: [ToolCall]?

    public init(role: String? = nil, content: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}
