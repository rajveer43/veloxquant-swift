import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The OpenAI `input` field: one string, or a batch of strings embedded in one call.
///
/// Typed replacement for Go's `EmbedRequest.Input any` ("a single string or a []string"), per
/// plan §3.9 — the same wire shape, without Go's untyped field.
public enum EmbedInput: Codable, Sendable, Equatable {
    /// A single string (encodes as a JSON string).
    case single(String)
    /// A batch of strings (encodes as a JSON array).
    case batch([String])

    /// Decodes a JSON string as `.single`, otherwise a string array as `.batch`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .single(single)
        } else {
            self = .batch(try container.decode([String].self))
        }
    }

    /// Encodes as a JSON string or array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .batch(let values): try container.encode(values)
        }
    }
}

/// An OpenAI-compatible `POST /v1/embeddings` request. Port of Go's `EmbedRequest`.
public struct EmbedRequest: Codable, Sendable, Equatable {
    /// Text to embed.
    public var input: EmbedInput
    /// Model to embed with; `nil` falls back to `VeloxQuantClient.defaultModel`, and is omitted
    /// from the wire if that is also `nil`.
    public var model: String?

    /// Creates a request.
    public init(input: EmbedInput, model: String? = nil) {
        self.input = input
        self.model = model
    }
}

/// One embedding vector, at the same `index` as its entry in `EmbedRequest.input`.
public struct Embedding: Codable, Sendable, Equatable {
    /// Position of the corresponding input.
    public let index: Int
    /// The embedding vector (wire key `embedding`; Go names the field `Vector`).
    public let vector: [Double]

    /// Creates an embedding.
    public init(index: Int, vector: [Double]) {
        self.index = index
        self.vector = vector
    }

    enum CodingKeys: String, CodingKey {
        case index
        case vector = "embedding"
    }
}

/// Token accounting for an embeddings call. OpenAI's embeddings `usage` has no
/// `completion_tokens`, so this is a separate type from chat's `Usage` (whose decoder requires
/// it); Go reuses one struct and silently zero-fills the missing field instead.
public struct EmbeddingUsage: Codable, Sendable, Equatable {
    /// Tokens in the input.
    public let promptTokens: Int
    /// Total tokens billed.
    public let totalTokens: Int

    /// Creates a usage record.
    public init(promptTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

/// An OpenAI-compatible embeddings response. Port of Go's `EmbedResponse`.
public struct EmbedResponse: Codable, Sendable, Equatable {
    /// The model that produced the embeddings, if the server reported one.
    public let model: String?
    /// One entry per input, in wire order.
    public let data: [Embedding]
    /// Token accounting, if the server reported it.
    public let usage: EmbeddingUsage?

    /// Creates a response.
    public init(model: String?, data: [Embedding], usage: EmbeddingUsage?) {
        self.model = model
        self.data = data
        self.usage = usage
    }

    /// Just the vectors, ordered by `index` (the plan's §3.9 `embeddings` shape).
    public var embeddings: [[Double]] {
        data.sorted { $0.index < $1.index }.map(\.vector)
    }
}

extension VeloxQuantClient {
    /// Embeds `request.input` via `POST /v1/embeddings` (OpenAI's request/response shape, as
    /// Go's `Client.Embed`).
    ///
    /// **Runtime caveat:** `mlx_lm.server`, which `veloxquant serve` wraps, does not currently
    /// serve `/v1/embeddings` (only chat/completions/models/health — verified against the
    /// installed `mlx_lm/server.py`), so against the VeloxQuant runtime today this fails with
    /// `VeloxQuantError.unexpectedRoute`. It works against OpenAI-compatible backends that do
    /// implement embeddings — the same situation as Go's `Embed`.
    public func embed(_ request: EmbedRequest) async throws -> EmbedResponse {
        var wireRequest = request
        if wireRequest.model == nil {
            wireRequest.model = defaultModel
        }
        do {
            let urlRequest = try makeRequest(for: wireRequest, path: "/v1/embeddings")
            let (data, response) = try await session.vqData(for: urlRequest)
            try validateResponse(data, response)
            return try JSONDecoder().decode(EmbedResponse.self, from: data)
        } catch {
            throw mapToVeloxQuantError(error)
        }
    }
}
