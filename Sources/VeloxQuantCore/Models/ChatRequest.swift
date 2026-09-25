import Foundation

/// Chat completion request. Every field traces to investigation §1.3's request schema, read
/// directly off `mlx_lm/server.py`'s field extraction — the authoritative request shape, since
/// nothing publishes it as a spec. No field is added beyond this list, and none are omitted.
public struct ChatRequest: Codable, Sendable {
    public var messages: [Message]
    public var model: String?
    public var stream: Bool
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var stop: StopSequence?
    public var tools: [ToolDefinition]?
    public var responseFormat: ResponseFormat?
    public var seed: Int?
    public var logitBias: [String: Double]?
    public var logprobs: Bool?
    public var topLogprobs: Int?
    public var repetitionPenalty: Double?
    public var repetitionContextSize: Int?
    public var presencePenalty: Double?
    public var presenceContextSize: Int?
    public var frequencyPenalty: Double?
    public var frequencyContextSize: Int?
    public var xtcProbability: Double?
    public var xtcThreshold: Double?
    public var chatTemplateKwargs: [String: JSONValue]?
    public var roleMapping: [String: String]?
    public var streamOptions: StreamOptions?

    public init(
        messages: [Message],
        model: String? = nil,
        stream: Bool = false,
        maxTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        stop: StopSequence? = nil,
        tools: [ToolDefinition]? = nil,
        responseFormat: ResponseFormat? = nil,
        seed: Int? = nil,
        logitBias: [String: Double]? = nil,
        logprobs: Bool? = nil,
        topLogprobs: Int? = nil,
        repetitionPenalty: Double? = nil,
        repetitionContextSize: Int? = nil,
        presencePenalty: Double? = nil,
        presenceContextSize: Int? = nil,
        frequencyPenalty: Double? = nil,
        frequencyContextSize: Int? = nil,
        xtcProbability: Double? = nil,
        xtcThreshold: Double? = nil,
        chatTemplateKwargs: [String: JSONValue]? = nil,
        roleMapping: [String: String]? = nil,
        streamOptions: StreamOptions? = nil
    ) {
        self.messages = messages
        self.model = model
        self.stream = stream
        self.maxTokens = maxTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.stop = stop
        self.tools = tools
        self.responseFormat = responseFormat
        self.seed = seed
        self.logitBias = logitBias
        self.logprobs = logprobs
        self.topLogprobs = topLogprobs
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
        self.presenceContextSize = presenceContextSize
        self.frequencyPenalty = frequencyPenalty
        self.frequencyContextSize = frequencyContextSize
        self.xtcProbability = xtcProbability
        self.xtcThreshold = xtcThreshold
        self.chatTemplateKwargs = chatTemplateKwargs
        self.roleMapping = roleMapping
        self.streamOptions = streamOptions
    }

    enum CodingKeys: String, CodingKey {
        case messages, model, stream, temperature, seed, tools, stop
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case responseFormat = "response_format"
        case logitBias = "logit_bias"
        case logprobs
        case topLogprobs = "top_logprobs"
        case repetitionPenalty = "repetition_penalty"
        case repetitionContextSize = "repetition_context_size"
        case presencePenalty = "presence_penalty"
        case presenceContextSize = "presence_context_size"
        case frequencyPenalty = "frequency_penalty"
        case frequencyContextSize = "frequency_context_size"
        case xtcProbability = "xtc_probability"
        case xtcThreshold = "xtc_threshold"
        case chatTemplateKwargs = "chat_template_kwargs"
        case roleMapping = "role_mapping"
        case streamOptions = "stream_options"
    }
}

/// The wire's `stop` field accepts either a single string or an array of strings.
public enum StopSequence: Codable, Sendable, Equatable {
    case single(String)
    case multiple([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .single(single)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .multiple(let values): try container.encode(values)
        }
    }
}

/// Requests a final usage-only SSE frame before `[DONE]` (investigation §1.5).
public struct StreamOptions: Codable, Sendable, Equatable {
    public var includeUsage: Bool

    public init(includeUsage: Bool = true) {
        self.includeUsage = includeUsage
    }

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

/// Response-format hint, in OpenAI's `response_format` wire shape (`{"type": "json_object"}` or
/// `{"type": "json_schema", "json_schema": {...}}`).
///
/// **Not enforced by the VeloxQuant runtime today.** `mlx_lm/server.py`'s `do_POST` does not read
/// this field off the request body at all (investigation §4.2) — it is forwarded on the wire for
/// forward-compatibility and for OpenAI-compatible backends that do honor it, but the local
/// runtime will not constrain decoding to match it. This is the same caveat Go's
/// `ChatRequest.ResponseFormat` documents. Prompt the model explicitly for the shape you want
/// and validate its output — `VeloxQuantClient.chatStructured(_:format:as:)` does both for you
/// and returns a `StructuredResult` that forces callers to handle a parse failure.
public enum ResponseFormat: Codable, Sendable, Equatable {
    /// `{"type": "json_schema", "json_schema": {...}}`.
    case jsonSchema(JSONSchema)
    /// `{"type": "json_object"}`.
    case jsonObject

    /// Requests a JSON object response without constraining it to a schema. Swift spelling of
    /// Go's `JSONMode()` helper.
    public static var jsonMode: ResponseFormat { .jsonObject }

    /// Requests a response constrained to `schema` (a JSON Schema object). Swift spelling of Go's
    /// `JSONSchema(name, schema, strict)` helper; `strict` requests exact adherence from
    /// backends that support it (the VeloxQuant runtime does not — see the type's doc comment).
    public static func jsonSchema(name: String, schema: [String: JSONValue], strict: Bool = false) -> ResponseFormat {
        .jsonSchema(JSONSchema(name: name, schema: schema, strict: strict))
    }

    private enum CodingKeys: String, CodingKey {
        case type, jsonSchema = "json_schema"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "json_object" {
            self = .jsonObject
        } else {
            self = .jsonSchema(try container.decode(JSONSchema.self, forKey: .jsonSchema))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .jsonObject:
            try container.encode("json_object", forKey: .type)
        case .jsonSchema(let schema):
            try container.encode("json_schema", forKey: .type)
            try container.encode(schema, forKey: .jsonSchema)
        }
    }

    /// A named JSON Schema constraint. `schema` is the top-level schema object; nested
    /// `properties`/`items` are representable via `JSONValue.object`/`.array`.
    public struct JSONSchema: Codable, Sendable, Equatable {
        /// Identifies the schema.
        public let name: String
        /// The JSON Schema document (a JSON object).
        public let schema: [String: JSONValue]
        /// Requests exact schema adherence, for backends that support it.
        public let strict: Bool

        /// Creates a named schema constraint.
        public init(name: String, schema: [String: JSONValue], strict: Bool = false) {
            self.name = name
            self.schema = schema
            self.strict = strict
        }
    }
}
