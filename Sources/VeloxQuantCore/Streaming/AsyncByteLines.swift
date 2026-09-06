import Foundation

extension AsyncSequence where Element == UInt8 {
    /// Buffers raw bytes and yields them as newline-terminated `String` lines (the newline
    /// itself is stripped), decoding UTF-8 incrementally. This is the cross-platform
    /// replacement for Apple Foundation's `AsyncBytes.lines` — needed because
    /// `swift-corelibs-foundation` on Linux has no equivalent of `URLSession.bytes(for:)`'s
    /// `AsyncBytes` type at all, only a plain `AsyncSequence<UInt8>` (see
    /// `URLSessionCompat.swift`). Behaves identically to `.lines` for this SDK's SSE-parsing
    /// purposes: `\n` and `\r\n` both terminate a line.
    var vqLines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                do {
                    for try await byte in self {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") {
                                buffer.removeLast()
                            }
                            // String(decoding:as:) never fails (invalid sequences become
                            // U+FFFD) — the right choice here since these bytes are SSE line
                            // buffers from our own controlled parsing, not untrusted encoded
                            // input a failable initializer should reject.
                            // swiftlint:disable:next optional_data_string_conversion
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        // swiftlint:disable:next optional_data_string_conversion
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
