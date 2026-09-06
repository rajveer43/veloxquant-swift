import Foundation

/// Non-streaming chat completion response (investigation §1.4).
public struct ChatResponse: Codable, Sendable, Equatable {
    public let id: String
    public let model: String
    public let choice: Choice
    public let usage: Usage

    public init(id: String, model: String, choice: Choice, usage: Usage) {
        self.id = id
        self.model = model
        self.choice = choice
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, choices, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        let choices = try container.decode([Choice].self, forKey: .choices)
        guard let first = choices.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .choices,
                in: container,
                debugDescription: "chat.completion response had an empty choices array"
            )
        }
        choice = first
        usage = try container.decode(Usage.self, forKey: .usage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode([choice], forKey: .choices)
        try container.encode(usage, forKey: .usage)
    }
}

/// A single choice in a non-streaming `ChatResponse`.
public struct Choice: Codable, Sendable, Equatable {
    public let index: Int
    public let message: AssistantMessage
    public let finishReason: FinishReason?

    public init(index: Int, message: AssistantMessage, finishReason: FinishReason?) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

/// The assistant's reply content within a `Choice`.
public struct AssistantMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let toolCalls: [ToolCall]?

    public init(role: String = "assistant", content: String, toolCalls: [ToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

/// Reported completion stop reason.
public enum FinishReason: String, Codable, Sendable {
    case stop, length
    case toolCalls = "tool_calls"
}

private struct PromptTokensDetails: Codable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

/// Token usage accounting, present on both non-streaming responses and the final SSE frame.
public struct Usage: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let cachedTokens: Int?

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int, cachedTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        completionTokens = try container.decode(Int.self, forKey: .completionTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        let details = try container.decodeIfPresent(PromptTokensDetails.self, forKey: .promptTokensDetails)
        cachedTokens = details?.cachedTokens
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(totalTokens, forKey: .totalTokens)
        if let cachedTokens {
            try container.encode(PromptTokensDetails(cachedTokens: cachedTokens), forKey: .promptTokensDetails)
        }
    }
}
