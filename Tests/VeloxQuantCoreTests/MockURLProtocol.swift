import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Box for `MockURLProtocol`'s test-registered handler closures. `nonisolated(unsafe)`
/// requires Swift 5.10+; this package's floor is 5.9 (plan §6.5), so this uses the
/// pre-5.10-compatible `@unchecked Sendable` pattern instead — safe here because tests never
/// register a handler concurrently with a request using it.
final class MockHandlerBox<Handler>: @unchecked Sendable {
    var value: Handler?
}

/// Foundation's built-in HTTP-mocking mechanism — the direct Swift analogue of Ktor's
/// `MockEngine`, requiring no additional dependency. Register `MockURLProtocol.handler`, then
/// build a `URLSession` whose configuration includes this protocol class.
final class MockURLProtocol: URLProtocol {
    static let handlerBox = MockHandlerBox<(URLRequest) throws -> (HTTPURLResponse, Data)>()
    static let streamHandlerBox = MockHandlerBox<(URLRequest) throws -> (HTTPURLResponse, [String])>()

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerBox.value }
        set { handlerBox.value = newValue }
    }

    static var streamHandler: ((URLRequest) throws -> (HTTPURLResponse, [String]))? {
        get { streamHandlerBox.value }
        set { streamHandlerBox.value = newValue }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let streamHandler = MockURLProtocol.streamHandler {
            do {
                let (response, lines) = try streamHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for line in lines {
                    let chunk = Data((line + "\n").utf8)
                    client?.urlProtocol(self, didLoad: chunk)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

        guard let handler = MockURLProtocol.handler else {
            fatalError("MockURLProtocol.handler not set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

enum MockURLProtocolError: Error {
    case missingURL
    case invalidResponse
}

/// Builds an `HTTPURLResponse` without force-unwrapping, for use inside test handler closures.
func mockResponse(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
    guard let url = request.url else { throw MockURLProtocolError.missingURL }
    guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
        throw MockURLProtocolError.invalidResponse
    }
    return response
}

/// The body of a request seen by `MockURLProtocol`. `URLSession` moves `httpBody` into
/// `httpBodyStream` before a `URLProtocol` sees it, so this reads whichever is present.
func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

/// The `messages` array of a chat request body, as `[[String: Any]]`.
func requestMessages(_ request: URLRequest) -> [[String: Any]] {
    let object = try? JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
    return object?["messages"] as? [[String: Any]] ?? []
}

/// A minimal non-streaming `chat.completion` body replying with `content`.
func chatCompletionJSON(content: String, completionTokens: Int = 2) -> Data {
    let body: [String: Any] = [
        "id": "chatcmpl-test",
        "model": "test-model",
        "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        "usage": ["prompt_tokens": 3, "completion_tokens": completionTokens, "total_tokens": 3 + completionTokens]
    ]
    return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
}
