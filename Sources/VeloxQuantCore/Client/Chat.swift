import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VeloxQuantClient {
    /// Sends a non-streaming chat completion request to `POST /v1/chat/completions`.
    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        var nonStreamingRequest = request
        nonStreamingRequest.stream = false
        do {
            let urlRequest = try makeRequest(for: nonStreamingRequest, path: "/v1/chat/completions")
            let (data, response) = try await session.vqData(for: urlRequest)
            try validateResponse(data, response)
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw mapToVeloxQuantError(error)
        }
    }
}
