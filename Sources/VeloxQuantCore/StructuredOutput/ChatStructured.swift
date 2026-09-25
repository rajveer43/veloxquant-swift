import Foundation

/// The outcome of `VeloxQuantClient.chatStructured(_:format:as:)`.
///
/// Deliberately not "return `T` or throw": the VeloxQuant runtime does not enforce
/// `response_format` (see `ResponseFormat`), so a non-conforming reply is an expected outcome,
/// not an exceptional one. Both cases keep the model's `raw` text so callers can implement
/// their own repair/retry. Not constrained to `T: Sendable` (plan §3.8): `T` is a caller-defined
/// model decoded once and handed back within the same call.
public enum StructuredResult<T> {
    /// The reply parsed as `T`.
    case parsed(T, raw: String)
    /// The reply did not parse as `T`; `error` is the decoding error.
    case parseFailed(raw: String, error: Error)

    /// The model's raw reply text, in either case.
    public var raw: String {
        switch self {
        case .parsed(_, let raw): return raw
        case .parseFailed(let raw, _): return raw
        }
    }
}

extension VeloxQuantClient {
    /// Best-effort structured output: asks the model for JSON matching `format`, then decodes
    /// the reply as `T`.
    ///
    /// This is a prompt-injection fallback, **not** grammar-constrained decoding — exactly the
    /// TS SDK's approach (`veloxquant-sdk/src/chat.ts`, `formatInstructions`/
    /// `parseResponseFormat`): the formatting instruction is appended as a trailing system
    /// message (so it survives whatever system prompt the caller supplied), `response_format` is
    /// still sent on the wire for forward-compatibility (inert on `mlx_lm.server` today), and
    /// markdown code fences a model may wrap its JSON in are stripped before decoding. No other
    /// repair is attempted.
    ///
    /// - Returns: `.parsed` or `.parseFailed` — never throws for a reply that fails to parse
    ///   (and never throws `VeloxQuantError.malformedStructuredOutput`, which exists only for
    ///   lower-level callers bypassing this API).
    /// - Throws: `VeloxQuantError` for transport/server failures, exactly as `chat(_:)`.
    public func chatStructured<T: Decodable>(
        _ request: ChatRequest,
        format: ResponseFormat,
        as type: T.Type
    ) async throws -> StructuredResult<T> {
        var structuredRequest = request
        structuredRequest.responseFormat = format
        structuredRequest.messages.append(.system(Self.formatInstructions(for: format)))

        let response = try await chat(structuredRequest)
        let raw = response.choice.message.content
        do {
            let value = try JSONDecoder().decode(T.self, from: Data(Self.strippingCodeFences(raw).utf8))
            return .parsed(value, raw: raw)
        } catch {
            return .parseFailed(raw: raw, error: error)
        }
    }

    /// The trailing system instruction for `format` — TS's `formatInstructions`, verbatim, with
    /// the schema serialized compactly (keys sorted, for deterministic requests).
    static func formatInstructions(for format: ResponseFormat) -> String {
        let fenceClause = "no markdown code fences, no commentary before or after it."
        switch format {
        case .jsonObject:
            return "Respond with a single valid JSON object and nothing else — \(fenceClause)"
        case .jsonSchema(let schema):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let schemaJSON = (try? encoder.encode(schema.schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "Respond with a single valid JSON object matching this JSON Schema, and nothing else — "
                + "\(fenceClause)\n\nJSON Schema:\n\(schemaJSON)"
        }
    }

    /// Strips a leading ```` ``` ````/```` ```json ```` fence and a trailing ```` ``` ```` — TS's
    /// `parseResponseFormat` pre-processing.
    static func strippingCodeFences(_ text: String) -> String {
        var stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("```") {
            stripped.removeFirst(3)
            if stripped.lowercased().hasPrefix("json") {
                stripped.removeFirst(4)
            }
            stripped = String(stripped.drop { $0.isWhitespace })
        }
        if stripped.hasSuffix("```") {
            stripped.removeLast(3)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
