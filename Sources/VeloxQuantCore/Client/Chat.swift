import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VeloxQuantClient {
    /// Sends a non-streaming chat completion request to `POST /v1/chat/completions`.
    ///
    /// If a `Monitor` is attached (`monitor(interval:sampler:)`), a successful call reports
    /// `tokensPerSecond = usage.completionTokens / wall-clock duration`, exactly as Go's
    /// `Client.Chat` computes it. `timeToFirstToken` is `nil` (not measured) for a
    /// non-streaming call, where Go reports a zero value.
    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        var nonStreamingRequest = request
        nonStreamingRequest.stream = false
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let urlRequest = try makeRequest(for: nonStreamingRequest, path: "/v1/chat/completions")
            let (data, response) = try await session.vqData(for: urlRequest)
            try validateResponse(data, response)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            let elapsed = clock.now - start
            metricsSink.report(
                tokensPerSecond: Self.tokensPerSecond(count: decoded.usage.completionTokens, over: elapsed),
                timeToFirstToken: nil
            )
            return decoded
        } catch {
            throw mapToVeloxQuantError(error)
        }
    }

    /// `count / elapsed` in per-second units, or `nil` when either is zero — Go's
    /// `if CompletionTokens > 0 && elapsed > 0` guard.
    static func tokensPerSecond(count: Int, over elapsed: Duration) -> Double? {
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard count > 0, seconds > 0 else { return nil }
        return Double(count) / seconds
    }
}
