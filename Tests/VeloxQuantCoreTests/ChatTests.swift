import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

final class ChatTests: XCTestCase {
    private func makeClient() -> VeloxQuantClient {
        VeloxQuantClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamHandler = nil
        super.tearDown()
    }

    func testChatDecodesNormalResponse() async throws {
        let json = """
        {
            "id": "chatcmpl-1",
            "model": "test-model",
            "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "Hello!"}, "finish_reason": "stop"}
            ],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
        }
        """
        MockURLProtocol.handler = { request in
            let response = try mockResponse(for: request, statusCode: 200)
            return (response, Data(json.utf8))
        }

        let client = makeClient()
        let response = try await client.chat(ChatRequest(messages: [.user("Hi")]))

        XCTAssertEqual(response.id, "chatcmpl-1")
        XCTAssertEqual(response.choice.message.content, "Hello!")
        XCTAssertEqual(response.choice.finishReason, .stop)
        XCTAssertEqual(response.usage.totalTokens, 7)
    }

    func test404WithJSONBodyThrowsGenerationFailed() async throws {
        MockURLProtocol.handler = { request in
            let response = try mockResponse(for: request, statusCode: 404)
            return (response, Data(#"{"error":"generation failed: something broke"}"#.utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.chat(ChatRequest(messages: [.user("Hi")]))
            XCTFail("Expected VeloxQuantError.generationFailed")
        } catch VeloxQuantError.generationFailed(let message) {
            XCTAssertEqual(message, "generation failed: something broke")
        }
    }

    func test404WithPlainTextNotFoundThrowsUnexpectedRoute() async throws {
        MockURLProtocol.handler = { request in
            let response = try mockResponse(for: request, statusCode: 404)
            return (response, Data("Not Found".utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.chat(ChatRequest(messages: [.user("Hi")]))
            XCTFail("Expected VeloxQuantError.unexpectedRoute")
        } catch VeloxQuantError.unexpectedRoute {
            // expected
        }
    }

    func testMalformedNonJSON404ThrowsMalformedErrorResponse() async throws {
        MockURLProtocol.handler = { request in
            let response = try mockResponse(for: request, statusCode: 404)
            return (response, Data("<html>internal server garbage</html>".utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.chat(ChatRequest(messages: [.user("Hi")]))
            XCTFail("Expected VeloxQuantError.malformedErrorResponse")
        } catch VeloxQuantError.malformedErrorResponse(let statusCode, let rawBody) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertTrue(rawBody.contains("garbage"))
        }
    }

    func testNon404ErrorWithJSONBodyThrowsServerError() async throws {
        MockURLProtocol.handler = { request in
            let response = try mockResponse(for: request, statusCode: 500)
            return (response, Data(#"{"error":"internal error"}"#.utf8))
        }

        let client = makeClient()
        do {
            _ = try await client.chat(ChatRequest(messages: [.user("Hi")]))
            XCTFail("Expected VeloxQuantError.serverError")
        } catch VeloxQuantError.serverError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(message, "internal error")
        }
    }

    func testConnectionRefusedThrowsRuntimeUnreachable() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let client = makeClient()
        do {
            _ = try await client.chat(ChatRequest(messages: [.user("Hi")]))
            XCTFail("Expected VeloxQuantError.runtimeUnreachable")
        } catch VeloxQuantError.runtimeUnreachable {
            // expected
        }
    }
}
