import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VeloxQuantClient {
    /// Streams a chat completion via `POST /v1/chat/completions` with `stream: true`, parsing
    /// Server-Sent Events using `URLSession.bytes(for:)`'s native `AsyncSequence<UInt8>` — no
    /// third-party SSE library needed (investigation §1.5/§5.2).
    ///
    /// `continuation.onTermination` cancels the backing `Task` — there is no manual
    /// `.close()`/`.cancel()` API. A consumer that stops iterating (breaks out of `for await`,
    /// or whose enclosing `Task` is cancelled) automatically tears down the underlying
    /// `URLSessionTask`.
    public func chatStream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    var streamingRequest = request
                    streamingRequest.stream = true
                    let urlRequest = try makeRequest(for: streamingRequest, path: "/v1/chat/completions")
                    let (bytes, response) = try await session.vqBytes(for: urlRequest)
                    try validateStreamingResponse(response)

                    for try await line in bytes.vqLines {
                        // SSE keepalive comment (`: keepalive N/M`, investigation §1.5) — a
                        // line starting with `:` is a comment per the SSE spec and must be
                        // skipped, not treated as data. Built as an explicit, auditable branch
                        // here rather than an accidental side effect of a narrower match.
                        if line.hasPrefix(":") { continue }
                        if line.isEmpty { continue }
                        guard line.hasPrefix("data:") else { continue }

                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        let data = Data(payload.utf8)
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapToVeloxQuantError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
