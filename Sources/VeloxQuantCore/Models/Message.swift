import Foundation

/// A single chat message. Enum-with-payload is the direct Swift analogue of Kotlin's sealed
/// `Message` interface (`System`/`User`/`Assistant`/`Tool` data classes) — custom `Codable`
/// conformance encodes/decodes the wire's `{role, content, tool_calls?, tool_call_id?}` shape.
public enum Message: Codable, Sendable, Equatable {
    case system(String)
    case user(String)
    case assistant(String, toolCalls: [ToolCall]? = nil)
    case tool(toolCallID: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallID = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "system":
            self = .system(try container.decode(String.self, forKey: .content))
        case "user":
            self = .user(try container.decode(String.self, forKey: .content))
        case "assistant":
            let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            let toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
            self = .assistant(content, toolCalls: toolCalls)
        case "tool":
            let toolCallID = try container.decode(String.self, forKey: .toolCallID)
            let content = try container.decode(String.self, forKey: .content)
            self = .tool(toolCallID: toolCallID, content: content)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "Unrecognized message role: \(role)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let content):
            try container.encode("system", forKey: .role)
            try container.encode(content, forKey: .content)
        case .user(let content):
            try container.encode("user", forKey: .role)
            try container.encode(content, forKey: .content)
        case .assistant(let content, let toolCalls):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        case .tool(let toolCallID, let content):
            try container.encode("tool", forKey: .role)
            try container.encode(toolCallID, forKey: .toolCallID)
            try container.encode(content, forKey: .content)
        }
    }
}

/// A tool call the assistant requested, per OpenAI's `tool_calls` shape.
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    private enum CodingKeys: String, CodingKey {
        case id, function
    }

    private enum FunctionCodingKeys: String, CodingKey {
        case name, arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let functionContainer = try container.nestedContainer(keyedBy: FunctionCodingKeys.self, forKey: .function)
        name = try functionContainer.decode(String.self, forKey: .name)
        argumentsJSON = try functionContainer.decode(String.self, forKey: .arguments)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        var functionContainer = container.nestedContainer(keyedBy: FunctionCodingKeys.self, forKey: .function)
        try functionContainer.encode(name, forKey: .name)
        try functionContainer.encode(argumentsJSON, forKey: .arguments)
    }
}

/// A tool definition offered to the model, per the wire's `tools` array (investigation §1.3).
public struct ToolDefinition: Codable, Sendable, Equatable {
    public var type: String
    public var function: FunctionDefinition

    public init(type: String = "function", function: FunctionDefinition) {
        self.type = type
        self.function = function
    }
}

/// The name/description/JSON-schema-parameters of a callable tool, per OpenAI's `function`
/// shape.
///
/// `parameters` uses `[String: JSONValue]` rather than a dedicated JSON-Schema type: `JSONValue`
/// (ported verbatim from Studio, per `JSONValue.swift`'s doc comment) only has scalar cases
/// (string/int/double/bool/null), matching every use of it that already exists in this exact
/// codebase (`ConfigField.defaultValue`, `RecommendedConfig.knobs`) — none of which need
/// arbitrary nesting. An actual JSON Schema object (with nested objects/arrays for
/// `properties`/`items`) does not fit this shape. This is a known, flagged gap: Phase 6's
/// `ResponseFormat.JSONSchema.schema` field has the identical problem and needs its own
/// resolution then (a recursive `JSONValue` with `.array`/`.object` cases, most likely) —
/// noted here rather than silently worked around, since `tools`/`function calling` is a
/// v1 wire field this phase must still cover even though full JSON-Schema-shaped parameters
/// are not yet representable.
public struct FunctionDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: [String: JSONValue]?

    public init(name: String, description: String? = nil, parameters: [String: JSONValue]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
