import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for a running `veloxquant serve` process. Plain `init` with default parameter
/// values — no builder is needed, since Objective-C interop is explicitly not a v1 goal (no
/// analogous "large population of callers who aren't in the SDK's own source language" the way
/// Kotlin's Java-on-the-JVM callers are).
///
/// `baseURL` defaults to `http://127.0.0.1:8000`, deliberately matching `serve.py`'s own
/// `--port` default (investigation §1.7) — this SDK never reproduces Go's confirmed
/// split-default-port bug.
///
/// `Sendable` conformance is declared explicitly because this type is designed to be safely
/// shared and called concurrently from multiple `Task`s — Swift's compiler-enforced analogue
/// of Kotlin's "coroutine-safe by convention" approach, and not optional here the way it was a
/// stylistic choice in Kotlin: Swift's strict concurrency checking flags any `Sendable`
/// violation crossing an `async` boundary as a compile error.
public final class VeloxQuantClient: Sendable {
    public let baseURL: URL
    public let defaultModel: String?

    let session: URLSession
    let requestTimeout: TimeInterval
    /// Where `chat()`/`chatStream()` push live inference metrics — see `monitor(interval:sampler:)`.
    let metricsSink = MetricsSinkBox()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        defaultModel: String? = nil,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.session = session
        self.requestTimeout = requestTimeout
    }

    func makeRequest(for body: some Encodable, path: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
