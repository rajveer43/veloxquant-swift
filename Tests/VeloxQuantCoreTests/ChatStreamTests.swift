import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

final class ChatStreamTests: XCTestCase {
    private func makeClient() -> VeloxQuantClient {
        VeloxQuantClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamHandler = nil
        super.tearDown()
    }

    func testChatStreamYieldsChunksAndSkipsKeepaliveComments() async throws {
        MockURLProtocol.streamHandler = { request in
            let response = try mockResponse(for: request, statusCode: 200)
            let lines = [
                ": keepalive 1/3",
                "",
                #"data: {"id":"c1","choices":[{"delta":{"content":"Hel"}}]}"#,
                ": keepalive 2/3",
                #"data: {"id":"c1","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
                "data: [DONE]"
            ]
            return (response, lines)
        }

        let client = makeClient()
        var received: [ChatChunk] = []
        for try await chunk in client.chatStream(ChatRequest(messages: [.user("Hi")])) {
            received.append(chunk)
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].delta?.content, "Hel")
        XCTAssertEqual(received[1].delta?.content, "lo")
        XCTAssertEqual(received[1].finishReason, .stop)
    }

    func testChatStreamHandlesUsageOnlyFinalFrame() async throws {
        MockURLProtocol.streamHandler = { request in
            let response = try mockResponse(for: request, statusCode: 200)
            let usageOnlyFrame = #"""
            {"object":"chat.completion","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}
            """#
            let lines = [
                #"data: {"id":"c1","choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#,
                "data: \(usageOnlyFrame)",
                "data: [DONE]"
            ]
            return (response, lines)
        }

        let client = makeClient()
        var received: [ChatChunk] = []
        for try await chunk in client.chatStream(ChatRequest(messages: [.user("Hi")])) {
            received.append(chunk)
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertNil(received[0].usage)
        XCTAssertNil(received[1].delta)
        XCTAssertEqual(received[1].usage?.totalTokens, 4)
    }

    func testChatStreamStopsOnUnexpectedRouteFor404() async throws {
        MockURLProtocol.streamHandler = { request in
            let response = try mockResponse(for: request, statusCode: 404)
            return (response, [])
        }

        let client = makeClient()
        do {
            for try await _ in client.chatStream(ChatRequest(messages: [.user("Hi")])) {
                XCTFail("Expected no chunks")
            }
            XCTFail("Expected VeloxQuantError.unexpectedRoute")
        } catch VeloxQuantError.unexpectedRoute {
            // expected
        }
    }
}
