import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

final class StructuredOutputAndEmbeddingsTests: XCTestCase {
    private struct Person: Decodable, Equatable {
        let name: String
        let age: Int
    }

    private let personSchema = ResponseFormat.jsonSchema(
        name: "person",
        schema: [
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("name"), .string("age")])
        ]
    )

    private func makeClient() -> VeloxQuantClient {
        VeloxQuantClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamHandler = nil
        super.tearDown()
    }

    // MARK: - Structured output

    func testChatStructuredParsesConformingReplyAndSendsInstructionAndResponseFormat() async throws {
        let seenBody = MockHandlerBox<[String: Any]>()
        MockURLProtocol.handler = { request in
            seenBody.value = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            let reply = chatCompletionJSON(content: #"{"name":"Ada","age":36}"#)
            return (try mockResponse(for: request, statusCode: 200), reply)
        }

        let result = try await makeClient().chatStructured(
            ChatRequest(messages: [.system("be terse"), .user("who?")]),
            format: personSchema,
            as: Person.self
        )

        switch result {
        case .parsed(let person, let raw):
            XCTAssertEqual(person, Person(name: "Ada", age: 36))
            XCTAssertEqual(raw, #"{"name":"Ada","age":36}"#)
        case .parseFailed(let raw, let error):
            XCTFail("unexpected parse failure: \(error) raw=\(raw)")
        }

        let messages = seenBody.value?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 3, "instruction appended as a trailing system message")
        XCTAssertEqual(messages.last?["role"] as? String, "system")
        let instruction = messages.last?["content"] as? String ?? ""
        XCTAssertTrue(instruction.hasPrefix("Respond with a single valid JSON object matching this JSON Schema"))
        XCTAssertTrue(instruction.contains(#""required":["name","age"]"#))
        XCTAssertEqual((seenBody.value?["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
    }

    func testChatStructuredStripsMarkdownFences() async throws {
        MockURLProtocol.handler = { request in
            let reply = chatCompletionJSON(content: "```json\n{\"name\":\"Bo\",\"age\":1}\n```")
            return (try mockResponse(for: request, statusCode: 200), reply)
        }
        let result = try await makeClient()
            .chatStructured(ChatRequest(messages: [.user("x")]), format: .jsonMode, as: Person.self)
        guard case .parsed(let person, _) = result else {
            return XCTFail("expected .parsed, got \(result)")
        }
        XCTAssertEqual(person.name, "Bo")
    }

    func testChatStructuredReturnsParseFailedWithRawInsteadOfThrowing() async throws {
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "Sure! Ada is 36."))
        }
        do {
            let result = try await makeClient()
                .chatStructured(ChatRequest(messages: [.user("x")]), format: personSchema, as: Person.self)
            switch result {
            case .parsed:
                XCTFail("expected .parseFailed")
            case .parseFailed(let raw, let error):
                XCTAssertEqual(raw, "Sure! Ada is 36.")
                XCTAssertTrue(error is DecodingError)
            }
        } catch VeloxQuantError.malformedStructuredOutput {
            XCTFail("chatStructured must never throw malformedStructuredOutput")
        }
    }

    func testChatStructuredStillThrowsTransportErrors() async {
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 404), Data("Not Found".utf8))
        }
        do {
            _ = try await makeClient()
                .chatStructured(ChatRequest(messages: [.user("x")]), format: .jsonMode, as: Person.self)
            XCTFail("expected unexpectedRoute")
        } catch VeloxQuantError.unexpectedRoute {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFormatInstructionsMatchTSWording() {
        XCTAssertEqual(
            VeloxQuantClient.formatInstructions(for: .jsonObject),
            "Respond with a single valid JSON object and nothing else — "
                + "no markdown code fences, no commentary before or after it."
        )
    }

    // MARK: - Embeddings

    func testEmbedSingleInputEncodesStringAndDecodesVectors() async throws {
        let seenInput = MockHandlerBox<Any>()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/embeddings")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            seenInput.value = body?["input"]
            let response = #"{"object":"list","model":"embed-model","#
                + #""data":[{"object":"embedding","index":0,"embedding":[0.1,-0.2,0.3]}],"#
                + #""usage":{"prompt_tokens":4,"total_tokens":4}}"#
            return (try mockResponse(for: request, statusCode: 200), Data(response.utf8))
        }

        let response = try await makeClient().embed(EmbedRequest(input: .single("hello"), model: "embed-model"))
        XCTAssertEqual(seenInput.value as? String, "hello")
        XCTAssertEqual(response.model, "embed-model")
        XCTAssertEqual(response.embeddings, [[0.1, -0.2, 0.3]])
        XCTAssertEqual(response.usage, EmbeddingUsage(promptTokens: 4, totalTokens: 4))
    }

    func testEmbedBatchInputEncodesArrayAndOrdersByIndex() async throws {
        let seenInput = MockHandlerBox<Any>()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            seenInput.value = body?["input"]
            let response = #"{"data":[{"index":1,"embedding":[2]},{"index":0,"embedding":[1]}]}"#
            return (try mockResponse(for: request, statusCode: 200), Data(response.utf8))
        }

        let response = try await makeClient().embed(EmbedRequest(input: .batch(["a", "b"])))
        XCTAssertEqual(seenInput.value as? [String], ["a", "b"])
        XCTAssertNil(response.model)
        XCTAssertNil(response.usage)
        XCTAssertEqual(response.embeddings, [[1], [2]])
    }

    func testEmbedAgainstMLXServerFailsWithUnexpectedRoute() async {
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 404), Data("Not Found".utf8))
        }
        do {
            _ = try await makeClient().embed(EmbedRequest(input: .single("x")))
            XCTFail("expected unexpectedRoute")
        } catch VeloxQuantError.unexpectedRoute {
            // expected: mlx_lm.server has no /v1/embeddings route
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testEmbedInputRoundTrips() throws {
        for input in [EmbedInput.single("a"), .batch(["a", "b"])] {
            XCTAssertEqual(try JSONDecoder().decode(EmbedInput.self, from: JSONEncoder().encode(input)), input)
        }
    }
}
