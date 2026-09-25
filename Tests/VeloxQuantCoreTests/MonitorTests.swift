import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

/// Ports of `veloxquant-go/monitor/monitor_test.go`, plus the live per-request metrics Go's
/// `Client.Monitor` pushes from `Chat`/`ChatStream`.
final class MonitorTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamHandler = nil
        super.tearDown()
    }

    /// Collects every delivered snapshot (thread-safe).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Metrics] = []
        func append(_ metrics: Metrics) {
            lock.lock()
            items.append(metrics)
            lock.unlock()
        }
        var all: [Metrics] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// Polls `condition` until true or `timeout` — portable across Apple XCTest and
    /// swift-corelibs-xctest (avoids depending on async `fulfillment(of:)`).
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("condition not met within \(timeout)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func testMonitorSamplesImmediatelyAndNotifies() async {
        let calls = Counter()
        let monitor = Monitor(
            sampler: MetricsSamplerFunction {
                _ = calls.increment()
                return Metrics(memoryUsedBytes: 100)
            },
            interval: .milliseconds(10)
        )
        let recorder = Recorder()
        monitor.subscribe { recorder.append($0) }

        monitor.start()
        await eventually { recorder.all.contains { $0.memoryUsedBytes == 100 } }
        monitor.stop()

        XCTAssertGreaterThan(calls.value, 0)
        XCTAssertEqual(monitor.latest?.memoryUsedBytes, 100)
    }

    func testStartAndStopAreIdempotent() {
        let monitor = Monitor(sampler: TimestampSampler(), interval: .milliseconds(10))
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testNonPositiveIntervalFallsBackToDefault() {
        XCTAssertEqual(Monitor(interval: .zero).interval, Monitor.defaultInterval)
        XCTAssertEqual(Monitor.defaultInterval, .seconds(5))
    }

    func testReportNotifiesImmediatelyWithoutStart() async {
        let monitor = Monitor(sampler: TimestampSampler(), interval: .seconds(3600))
        let recorder = Recorder()
        monitor.subscribe { recorder.append($0) }
        monitor.report(Metrics(tokensPerSecond: 42))
        XCTAssertEqual(recorder.all.map(\.tokensPerSecond), [42], "delivered synchronously, no tick needed")
        XCTAssertEqual(monitor.latest?.tokensPerSecond, 42)
    }

    func testSamplerErrorsSkipTheTick() async throws {
        struct SampleError: Error {}
        let monitor = Monitor(sampler: MetricsSamplerFunction { throw SampleError() }, interval: .milliseconds(5))
        monitor.start()
        try await Task.sleep(for: .milliseconds(50))
        monitor.stop()
        XCTAssertNil(monitor.latest)
    }

    func testUpdatesStreamDeliversReports() async {
        let monitor = Monitor(interval: .seconds(3600))
        let stream = monitor.updates()
        monitor.report(Metrics(tokensPerSecond: 7))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.tokensPerSecond, 7)
    }

    func testUnmeasuredFieldsAreNilNotZero() {
        let metrics = Metrics()
        XCTAssertNil(metrics.residentMemoryBytes)
        XCTAssertNil(metrics.tokensPerSecond)
        XCTAssertNil(metrics.timeToFirstTokenMs)
        XCTAssertEqual(Metrics(timeToFirstToken: .milliseconds(250)).timeToFirstTokenMs ?? 0, 250, accuracy: 1e-9)
    }

    // MARK: - Live per-request metrics

    func testChatPushesTokensPerSecondMergedOntoLastSample() async throws {
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "hi", completionTokens: 10))
        }
        let client = VeloxQuantClient(session: MockURLProtocol.makeSession())
        let monitor = client.monitor(
            interval: .seconds(3600),
            sampler: MetricsSamplerFunction { Metrics(memoryUsedBytes: 5, memoryAvailableBytes: 6) }
        )
        let recorder = Recorder()
        monitor.subscribe { recorder.append($0) }
        monitor.start()
        await eventually { !recorder.all.isEmpty }
        _ = try await client.chat(ChatRequest(messages: [.user("x")]))
        monitor.stop()

        let inference = try XCTUnwrap(recorder.all.first { $0.tokensPerSecond != nil })
        XCTAssertGreaterThan(inference.tokensPerSecond ?? 0, 0)
        XCTAssertNil(inference.timeToFirstToken, "non-streaming chat does not measure TTFT")
        XCTAssertEqual(inference.memoryUsedBytes, 5, "merged onto the last periodic sample")
        XCTAssertEqual(inference.memoryAvailableBytes, 6)
    }

    func testChatStreamPushesTimeToFirstTokenWhenStreamEnds() async throws {
        MockURLProtocol.streamHandler = { request in
            let lines = [
                #"data: {"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#,
                #"data: {"id":"c","choices":[{"delta":{"content":"a"}}]}"#,
                #"data: {"id":"c","choices":[{"delta":{"content":"b"},"finish_reason":"stop"}]}"#,
                "data: [DONE]"
            ]
            return (try mockResponse(for: request, statusCode: 200), lines)
        }
        let client = VeloxQuantClient(session: MockURLProtocol.makeSession())
        let monitor = client.monitor(interval: .seconds(3600))
        let recorder = Recorder()
        monitor.subscribe { recorder.append($0) }
        for try await _ in client.chatStream(ChatRequest(messages: [.user("x")])) {}
        await eventually { !recorder.all.isEmpty }
        XCTAssertEqual(recorder.all.count, 1, "reported exactly once, when the stream ends")
        XCTAssertNotNil(recorder.all.first?.timeToFirstToken)
        XCTAssertNotNil(recorder.all.first?.tokensPerSecond)
    }

    func testNoMonitorAttachedIsANoOp() async throws {
        MockURLProtocol.handler = { request in
            (try mockResponse(for: request, statusCode: 200), chatCompletionJSON(content: "hi"))
        }
        let client = VeloxQuantClient(session: MockURLProtocol.makeSession())
        let response = try await client.chat(ChatRequest(messages: [.user("x")]))
        XCTAssertEqual(response.choice.message.content, "hi")
    }
}
