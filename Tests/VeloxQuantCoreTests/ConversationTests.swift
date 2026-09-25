import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

/// Mirrors `veloxquant-go/conversation_test.go`, plus the stream-failure and abandoned-stream
/// cases the plan's "failed turn leaves history unchanged" contract requires.
final class ConversationTests: XCTestCase {
    private func makeClient() -> VeloxQuantClient {
        VeloxQuantClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamHandler = nil
        super.tearDown()
    }

    func testSendGrowsHistoryAndSendsFullHistoryEachTurn() async throws {
        let seen = MockHandlerBox<[[[String: Any]]]>()
        seen.value = []
        let reply = MockHandlerBox<String>()
        reply.value = "ok"
        MockURLProtocol.handler = { request in
            seen.value?.append(requestMessages(request))
            return (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: reply.value ?? ""))
        }

        let conversation = Conversation(client: makeClient(), model: "test-model")
        _ = try await conversation.send("hello")
        let afterOne = await conversation.history
        XCTAssertEqual(afterOne, [.user("hello"), .assistant("ok")])

        reply.value = "ok again"
        _ = try await conversation.send("how are you")
        let afterTwo = await conversation.history
        XCTAssertEqual(afterTwo.count, 4)
        XCTAssertEqual(afterTwo[3], .assistant("ok again"))

        let requests = seen.value ?? []
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].count, 3, "second request carries user, assistant, user")
        XCTAssertEqual(requests[1].map { $0["role"] as? String }, ["user", "assistant", "user"])
    }

    func testSystemPromptSeedsHistoryAndIsSent() async throws {
        let seen = MockHandlerBox<[[String: Any]]>()
        MockURLProtocol.handler = { request in
            seen.value = requestMessages(request)
            return (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "hi"))
        }

        let conversation = Conversation(client: makeClient(), system: "you are helpful")
        let initial = await conversation.history
        XCTAssertEqual(initial, [.system("you are helpful")])
        _ = try await conversation.send("hello")
        XCTAssertEqual(seen.value?.first?["role"] as? String, "system")
        XCTAssertEqual(seen.value?.count, 2)
    }

    func testEmptySystemPromptStartsWithNoHistory() async {
        let history = await Conversation(client: makeClient(), system: "").history
        XCTAssertTrue(history.isEmpty)
    }

    func testFailedSendLeavesHistoryUnchangedAndRetryStartsClean() async throws {
        let fail = MockHandlerBox<Bool>()
        fail.value = true
        MockURLProtocol.handler = { request in
            if fail.value == true {
                return (try mockResponse(for: request, statusCode: 500), Data(#"{"error":"boom"}"#.utf8))
            }
            return (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "recovered"))
        }

        let conversation = Conversation(client: makeClient(), system: "sys")
        do {
            _ = try await conversation.send("hello")
            XCTFail("expected failure")
        } catch VeloxQuantError.serverError(let status, _) {
            XCTAssertEqual(status, 500)
        }
        let afterFailure = await conversation.history
        XCTAssertEqual(afterFailure, [.system("sys")])

        fail.value = false
        _ = try await conversation.send("hello again")
        let afterRetry = await conversation.history
        XCTAssertEqual(afterRetry, [.system("sys"), .user("hello again"), .assistant("recovered")])
    }

    func testSendStreamCommitsConcatenatedReplyOnlyAfterSuccessfulFinish() async throws {
        MockURLProtocol.streamHandler = { request in
            let lines = [
                #"data: {"id":"c","choices":[{"delta":{"content":"hel"}}]}"#,
                #"data: {"id":"c","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
                "data: [DONE]"
            ]
            return (try mockResponse(for: request, statusCode: 200), lines)
        }

        let conversation = Conversation(client: makeClient())
        var text = ""
        for try await chunk in conversation.sendStream("hi") {
            text += chunk.delta?.content ?? ""
        }
        XCTAssertEqual(text, "hello")
        let history = await conversation.history
        XCTAssertEqual(history, [.user("hi"), .assistant("hello")])
    }

    func testSendStreamMidStreamFailureLeavesHistoryUnchanged() async throws {
        MockURLProtocol.streamHandler = { request in
            let lines = [
                #"data: {"id":"c","choices":[{"delta":{"content":"partial"}}]}"#,
                "data: {not valid json"
            ]
            return (try mockResponse(for: request, statusCode: 200), lines)
        }

        let conversation = Conversation(client: makeClient(), system: "sys")
        var received = 0
        do {
            for try await _ in conversation.sendStream("hi") {
                received += 1
            }
            XCTFail("expected the stream to throw")
        } catch is VeloxQuantError {
            // expected
        }
        XCTAssertEqual(received, 1)
        let history = await conversation.history
        XCTAssertEqual(history, [.system("sys")])
    }

    func testSendStreamErrorStatusLeavesHistoryUnchanged() async throws {
        MockURLProtocol.streamHandler = { request in
            (try mockResponse(for: request, statusCode: 500), [])
        }
        let conversation = Conversation(client: makeClient())
        do {
            for try await _ in conversation.sendStream("hi") {}
            XCTFail("expected failure")
        } catch is VeloxQuantError {}
        let history = await conversation.history
        XCTAssertTrue(history.isEmpty)
    }

    func testAbandonedStreamDoesNotRecordAPartialTurn() async throws {
        MockURLProtocol.streamHandler = { request in
            let lines = [
                #"data: {"id":"c","choices":[{"delta":{"content":"one"}}]}"#,
                #"data: {"id":"c","choices":[{"delta":{"content":"two"}}]}"#,
                "data: [DONE]"
            ]
            return (try mockResponse(for: request, statusCode: 200), lines)
        }
        let conversation = Conversation(client: makeClient())
        for try await _ in conversation.sendStream("hi") {
            break
        }
        // The mock delivers every line at once, so the producer may legitimately have finished
        // the whole turn before the consumer's break cancelled it. Either way, a *partial* reply
        // ("one") must never be recorded, and the turn lock must be released for the next turn.
        MockURLProtocol.streamHandler = nil
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "fine"))
        }
        _ = try await conversation.send("again")
        let history = await conversation.history
        XCTAssertEqual(Array(history.suffix(2)), [.user("again"), .assistant("fine")])
        XCTAssertTrue(history.count == 2 || history.prefix(2) == [.user("hi"), .assistant("onetwo")], "\(history)")
    }

    func testRequestsUseConversationModel() async throws {
        let model = MockHandlerBox<String>()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            model.value = body?["model"] as? String
            return (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "x"))
        }
        _ = try await Conversation(client: makeClient(), model: "m-1").send("hi")
        XCTAssertEqual(model.value, "m-1")
    }
}
