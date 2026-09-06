import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(FoundationNetworking)
/// `dataTask(with:completionHandler:)`'s completion handler only delivers the **last**
/// `URLProtocol.didLoad` chunk on `swift-corelibs-foundation`, not the accumulated
/// concatenation of every chunk a custom `URLProtocol` sent — verified directly against the
/// `swift:5.9` Docker image with a two-chunk mock response. This is a second, independent Linux
/// platform bug beyond the missing async `data(for:)`/`bytes(for:)` methods, discovered because
/// `MockURLProtocol`'s streaming test fixture (which calls `didLoad` once per SSE line) reduced
/// to only the final line's content instead of the full response. Fixed by driving the request
/// through `URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)`, which does accumulate
/// correctly (also verified directly) — bypassing the completion-handler API's accumulation bug
/// entirely rather than working around it.
private final class DataAccumulator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = Data()
    private let continuation: CheckedContinuation<(Data, URLResponse), Error>
    private var didResume = false

    init(continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didResume else { return }
        didResume = true
        if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (buffer, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
#endif

/// `URLSession.data(for:)`/`.bytes(for:)` async convenience APIs exist on Apple's Foundation
/// but are not implemented by `swift-corelibs-foundation` on Linux (verified directly: neither
/// Swift 5.9's nor 5.10's official `swift` Docker image exposes them) — a real platform gap the
/// plan/investigation did not anticipate, discovered only once the Linux CI leg actually ran
/// this code, not a bug in this SDK's own logic.
///
/// `VeloxQuantClient`'s call sites use `vqData(for:)`/`vqBytes(for:)` unconditionally: on Apple
/// platforms these resolve directly to the native async APIs (zero overhead, zero behavior
/// change); on Linux they resolve to a delegate-based shim (see `DataAccumulator` above). This
/// keeps every call site identical across platforms; only this one file differs.
extension URLSession {
    func vqData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DataAccumulator(continuation: continuation)
            let session = URLSession(configuration: self.configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            task.resume()
        }
        #else
        try await data(for: request)
        #endif
    }

    /// Returns response bytes as a type-erased `AsyncThrowingStream<UInt8, Error>` on every
    /// platform, so `ChatStream.swift`'s call site is identical regardless of which branch
    /// below actually ran.
    ///
    /// On Apple platforms, wraps the native `bytes(for:)`'s true incremental `AsyncBytes`
    /// sequence — streaming behavior is unchanged.
    ///
    /// On Linux, `swift-corelibs-foundation` has no incremental byte-streaming primitive at
    /// all (not even via a completion-handler equivalent to wrap) — this falls back to
    /// buffering the full response via `vqData(for:)` before yielding it as a single sequence
    /// of bytes. SSE frames are still parsed identically line-by-line, so this is correct, but
    /// it loses true incremental delivery on Linux. Accepted, documented platform limitation:
    /// `VeloxQuantRuntime` (streaming's most latency-sensitive real consumer) is macOS-only
    /// anyway, so Linux callers of `chatStream()` only lose incremental delivery, not
    /// correctness.
    func vqBytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        #if canImport(FoundationNetworking)
        let (data, response) = try await vqData(for: request)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        return (stream, response)
        #else
        let (nativeBytes, response) = try await bytes(for: request)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for try await byte in nativeBytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
        #endif
    }
}
