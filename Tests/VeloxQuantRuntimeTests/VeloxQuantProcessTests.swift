import XCTest
@testable import VeloxQuantCore
@testable import VeloxQuantRuntime

final class VeloxQuantProcessTests: XCTestCase {
    override func tearDown() {
        RuntimeMockURLProtocol.handlerBox.value = nil
        super.tearDown()
    }

    // MARK: - Argument building / handshake parsing

    func testServeArgumentsUseServePyFlagNames() {
        let config = ServeConfig(
            model: "mlx-community/Qwen3-8B-4bit",
            method: "kivi",
            bits: 3,
            port: 8123,
            promptCacheBytes: 2_000_000_000,
            setOverrides: ["kivi_group_size": "64", "bit_width_inlier": "4", "seed": "7"]
        )
        XCTAssertEqual(ServeConfig.serveArguments(for: config), [
            "serve", "--model", "mlx-community/Qwen3-8B-4bit", "--host", "127.0.0.1", "--port", "8123", "--bits", "3",
            "--method", "kivi", "--max-tokens", "512", "--temp", "0.0", "--top-p", "1.0", "--prompt-cache-size", "10",
            "--prompt-cache-bytes", "2000000000", "--set", "kivi_group_size=64"
        ])
    }

    func testDefaultsMatchServeAndClient() {
        let config = ServeConfig(model: "m")
        XCTAssertEqual(config.port, 8000)
        XCTAssertEqual(VeloxQuantClient().baseURL.port, config.port, "no split-default-port bug")
        XCTAssertEqual(config.readyTimeout, .seconds(300))
        XCTAssertNil(config.method)
        XCTAssertFalse(ServeConfig.serveArguments(for: config).contains("--method"))
    }

    func testReadyPayloadParsing() throws {
        let payload = try XCTUnwrap(ServeReadyPayload.parse(line: Fixtures.readyLine(port: 9001)))
        XCTAssertEqual(payload.port, 9001)
        XCTAssertEqual(payload.method, "turboquant_rvq")
        XCTAssertEqual(payload.endpoints.openaiBaseURL, "http://127.0.0.1:9001/v1")
        XCTAssertNil(payload.endpoints.kvStats)
        XCTAssertTrue(payload.accountingOnly)

        XCTAssertNil(try ServeReadyPayload.parse(line: "loading model..."))
        XCTAssertThrowsError(try ServeReadyPayload.parse(line: "VELOXQUANT_READY {oops"))
    }

    func testReadyPayloadAccountingOnlyDefaultsToTrueWhenAbsent() throws {
        let payload = try XCTUnwrap(ServeReadyPayload.parse(line: Fixtures.readyLine(accountingOnly: nil)))
        XCTAssertTrue(payload.accountingOnly)
    }

    func testBaseURLConnectsToLoopbackForWildcardHost() {
        XCTAssertEqual(VeloxQuantProcess.baseURL(host: "0.0.0.0", port: 8000)?.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(VeloxQuantProcess.baseURL(host: "192.168.1.5", port: 9)?.absoluteString, "http://192.168.1.5:9")
    }

    // MARK: - Readiness race

    /// The regression test for Go's confirmed hang: the fake emits the handshake **only** in
    /// response to the priming chat request — never on a timer or at launch. If the priming
    /// logic were removed, `start` would time out instead of succeeding.
    func testStartSucceedsWhenHandshakeOnlyFollowsThePrimingRequest() async throws {
        let fake = FakeServeProcess()
        let healthPolls = MockBox<Int>()
        healthPolls.value = 0
        RuntimeMockURLProtocol.handlerBox.value = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/health"):
                healthPolls.value = (healthPolls.value ?? 0) + 1
                return (200, Data("OK".utf8))
            case ("POST", "/v1/chat/completions"):
                fake.emitStdout("Fetching 7 files...")
                fake.emitStdout(Fixtures.readyLine(port: 8000))
                return (200, Fixtures.chatJSON())
            default:
                return (404, Data("Not Found".utf8))
            }
        }
        let launcher = FakeServeLauncher(process: fake)
        var config = ServeConfig(model: "m", readyTimeout: .seconds(5))
        config.method = "kivi"

        let process = try await VeloxQuantProcess.start(
            config: config,
            pythonEnvironment: Fixtures.python,
            launcher: launcher,
            session: RuntimeMockURLProtocol.makeSession()
        )

        XCTAssertGreaterThan(healthPolls.value ?? 0, 0, "health was polled before priming")
        XCTAssertEqual(process.readyPayload.method, "turboquant_rvq")
        XCTAssertEqual(process.baseURL.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(process.client.baseURL, process.baseURL)
        let state = await process.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(launcher.launched.value?.0, "/venv/bin/python3")
        XCTAssertEqual(Array(launcher.launched.value?.1.prefix(3) ?? []), ["-m", "veloxquant_mlx", "serve"])

        await process.stop(gracePeriod: .seconds(1))
        let stopped = await process.state
        XCTAssertEqual(stopped, .finished(exitCode: 130))
        XCTAssertEqual(fake.receivedSignals, ["SIGINT"], "SIGINT first; clean exit needs no escalation")
    }

    func testStartResolvesFromHandshakeAloneWhenServerNeverAnswers() async throws {
        let fake = FakeServeProcess()
        RuntimeMockURLProtocol.handlerBox.value = nil // every request fails: connection refused
        Task {
            try await Task.sleep(for: .milliseconds(50))
            fake.emitStdout(Fixtures.readyLine(host: "0.0.0.0", port: 8124))
        }
        let process = try await VeloxQuantProcess.start(
            config: ServeConfig(model: "m", port: 8124, readyTimeout: .seconds(5)),
            pythonEnvironment: Fixtures.python,
            launcher: FakeServeLauncher(process: fake),
            session: RuntimeMockURLProtocol.makeSession()
        )
        XCTAssertEqual(process.baseURL.absoluteString, "http://127.0.0.1:8124")
        await process.stop()
    }

    func testExitBeforeReadyThrowsServeProcessExitedWithStderr() async {
        let fake = FakeServeProcess()
        Task {
            try await Task.sleep(for: .milliseconds(20))
            fake.emitStderr("error: unknown method 'nope'")
            fake.exit(2)
        }
        do {
            _ = try await VeloxQuantProcess.start(
                config: ServeConfig(model: "m", method: "nope", readyTimeout: .seconds(5)),
                pythonEnvironment: Fixtures.python,
                launcher: FakeServeLauncher(process: fake),
                session: RuntimeMockURLProtocol.makeSession()
            )
            XCTFail("expected serveProcessExited")
        } catch VeloxQuantError.serveProcessExited(let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(stderr, "error: unknown method 'nope'")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTimeoutStopsProcessAndThrowsServeStartupTimeout() async {
        let fake = FakeServeProcess()
        do {
            _ = try await VeloxQuantProcess.start(
                config: ServeConfig(model: "m", port: 8125, readyTimeout: .milliseconds(200)),
                pythonEnvironment: Fixtures.python,
                launcher: FakeServeLauncher(process: fake),
                session: RuntimeMockURLProtocol.makeSession()
            )
            XCTFail("expected timeout")
        } catch VeloxQuantError.serveStartupTimeout(let model, let port, let timeout) {
            XCTAssertEqual(model, "m")
            XCTAssertEqual(port, 8125)
            XCTAssertEqual(timeout, .milliseconds(200))
            XCTAssertFalse(fake.isRunning, "a timed-out process is not left running")
            XCTAssertEqual(fake.receivedSignals.first, "SIGINT")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMalformedHandshakeThrowsMalformedCLIOutput() async {
        let fake = FakeServeProcess()
        Task {
            try await Task.sleep(for: .milliseconds(20))
            fake.emitStdout("VELOXQUANT_READY {not json")
        }
        do {
            _ = try await VeloxQuantProcess.start(
                config: ServeConfig(model: "m", readyTimeout: .seconds(5)),
                pythonEnvironment: Fixtures.python,
                launcher: FakeServeLauncher(process: fake),
                session: RuntimeMockURLProtocol.makeSession()
            )
            XCTFail("expected malformedCLIOutput")
        } catch VeloxQuantError.malformedCLIOutput(_, let raw, _) {
            XCTAssertEqual(raw, "VELOXQUANT_READY {not json")
            XCTAssertFalse(fake.isRunning)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Shutdown escalation

    func testStopEscalatesToSIGTERMThenSIGKILL() async throws {
        let fake = FakeServeProcess()
        fake.exitOnInterrupt = nil
        fake.exitOnTerminate = nil
        Task {
            try await Task.sleep(for: .milliseconds(20))
            fake.emitStdout(Fixtures.readyLine())
        }
        let process = try await VeloxQuantProcess.start(
            config: ServeConfig(model: "m", readyTimeout: .seconds(5)),
            pythonEnvironment: Fixtures.python,
            launcher: FakeServeLauncher(process: fake),
            session: RuntimeMockURLProtocol.makeSession()
        )
        await process.stop(gracePeriod: .milliseconds(50))
        XCTAssertEqual(fake.receivedSignals, ["SIGINT", "SIGTERM", "SIGKILL"])
        let state = await process.state
        XCTAssertEqual(state, .finished(exitCode: 137))

        await process.stop() // idempotent
        XCTAssertEqual(fake.receivedSignals.count, 3)
    }

    func testProcessExitingOnItsOwnUpdatesState() async throws {
        let fake = FakeServeProcess()
        Task {
            try await Task.sleep(for: .milliseconds(20))
            fake.emitStdout(Fixtures.readyLine())
        }
        let process = try await VeloxQuantProcess.start(
            config: ServeConfig(model: "m", readyTimeout: .seconds(5)),
            pythonEnvironment: Fixtures.python,
            launcher: FakeServeLauncher(process: fake),
            session: RuntimeMockURLProtocol.makeSession()
        )
        fake.exit(1)
        let code = await process.waitUntilExit()
        XCTAssertEqual(code, 1)
        for _ in 0..<50 {
            if await process.state == .finished(exitCode: 1) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = await process.state
        XCTAssertEqual(state, .finished(exitCode: 1))
        XCTAssertFalse(LiveServeProcesses.shared.livePIDs.contains(fake.processIdentifier))
    }

    // MARK: - Real Foundation.Process handle

    func testFoundationServeProcessStreamsLinesAndReportsExit() async throws {
        let handle = try FoundationServeProcessLauncher().launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo first; echo 'VELOXQUANT_READY {}'; echo oops >&2; exit 4"]
        )
        var stdout: [String] = []
        for await line in handle.stdoutLines {
            stdout.append(line)
        }
        var stderr: [String] = []
        for await line in handle.stderrLines {
            stderr.append(line)
        }
        let code = await handle.waitUntilExit()
        XCTAssertEqual(stdout, ["first", "VELOXQUANT_READY {}"])
        XCTAssertEqual(stderr, ["oops"])
        XCTAssertEqual(code, 4)
    }

    func testLineSplitterHandlesPartialLinesAndCRLF() {
        let splitter = LineSplitter()
        XCTAssertEqual(splitter.append(Data("ab".utf8)), [])
        XCTAssertEqual(splitter.append(Data("c\r\nde\nf".utf8)), ["abc", "de"])
        XCTAssertEqual(splitter.flush(), "f")
        XCTAssertNil(splitter.flush())
    }

    func testProcessSamplerReadsOwnResidentMemory() async throws {
        let metrics = try await ProcessMetricsSampler(processIdentifier: getpid()).sample()
        XCTAssertGreaterThan(metrics.residentMemoryBytes ?? 0, 0)
        XCTAssertGreaterThan(metrics.memoryAvailableBytes ?? 0, 0)
        let missing = try await ProcessMetricsSampler(processIdentifier: -1).sample()
        XCTAssertNil(missing.residentMemoryBytes)
    }
}
