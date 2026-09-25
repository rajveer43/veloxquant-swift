import Foundation
@testable import VeloxQuantCore
@testable import VeloxQuantRuntime

/// Records every call and answers from a closure — the hand-written fake behind
/// `ProcessRunning` (Studio's protocol-plus-fake convention).
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) throws -> ProcessOutput

    init(_ respond: @escaping @Sendable (Call) throws -> ProcessOutput) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessOutput {
        let call = Call(executable: executable, arguments: arguments)
        record(call)
        return try respond(call)
    }

    private func record(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }
}

extension ProcessOutput {
    static func success(_ stdout: String) -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: stdout, stderr: "")
    }

    static func failure(_ code: Int32, stderr: String) -> ProcessOutput {
        ProcessOutput(exitCode: code, stdout: "", stderr: stderr)
    }
}

/// A controllable `ServeProcessHandle`: tests decide exactly when stdout/stderr lines appear and
/// when the process exits.
final class FakeServeProcess: ServeProcessHandle, @unchecked Sendable {
    let stdoutLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>
    let processIdentifier: Int32 = 424_242

    private let stdoutContinuation: AsyncStream<String>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let exitState = ExitState()
    private let lock = NSLock()
    private var signals: [String] = []
    /// Exit code to use when a signal is received; `nil` ignores that signal.
    var exitOnInterrupt: Int32? = 130
    var exitOnTerminate: Int32? = 143

    init() {
        (stdoutLines, stdoutContinuation) = AsyncStream<String>.makeStream()
        (stderrLines, stderrContinuation) = AsyncStream<String>.makeStream()
    }

    var receivedSignals: [String] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    var isRunning: Bool { exitState.exitStatus == nil }

    func emitStdout(_ line: String) { stdoutContinuation.yield(line) }
    func emitStderr(_ line: String) { stderrContinuation.yield(line) }

    func exit(_ code: Int32) {
        stdoutContinuation.finish()
        stderrContinuation.finish()
        exitState.markExited(code)
    }

    func waitUntilExit() async -> Int32? { await exitState.wait() }

    func interrupt() {
        record("SIGINT")
        if let code = exitOnInterrupt { exit(code) }
    }

    func terminate() {
        record("SIGTERM")
        if let code = exitOnTerminate { exit(code) }
    }

    func kill() {
        record("SIGKILL")
        exit(137)
    }

    private func record(_ signal: String) {
        lock.lock()
        signals.append(signal)
        lock.unlock()
    }
}

struct FakeServeLauncher: ServeProcessLaunching {
    let process: FakeServeProcess
    let launched = MockBox<(String, [String])>()

    func launch(executable: String, arguments: [String]) throws -> ServeProcessHandle {
        launched.value = (executable, arguments)
        return process
    }
}

final class MockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// `URLProtocol` mock for the runtime's health poll / priming request.
final class RuntimeMockURLProtocol: URLProtocol {
    static let handlerBox = MockBox<@Sendable (URLRequest) throws -> (Int, Data)>()

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlerBox.value, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            guard let response else {
                throw URLError(.badServerResponse)
            }
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
        config.protocolClasses = [RuntimeMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

enum Fixtures {
    static let python = PythonEnvironment(interpreterPath: "/venv/bin/python3", veloxquantVersion: "0.71.1")

    static func recommendJSON(method: String = "turboquant_rvq", warnings: [String] = []) -> String {
        let warningsJSON = warnings.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "request": {"chip": "M3", "ram_gb": 16, "model_class": "14B", "goal": "everyday",
                      "seq_len": 8192, "n_layers": 36, "n_kv_heads": 8, "head_dim": 128},
          "recommendation": {
            "method": "\(method)",
            "knobs": {"bit_width_inlier": 1, "seed": 42},
            "key_accounting_ratio": 7.5,
            "resident_savings_likely": false,
            "kv_fp16_mb": 1152.0,
            "kv_compressed_mb_estimate": 153.6,
            "warnings": [\(warningsJSON)],
            "rationale": "Everyday default."
          }
        }
        """
    }

    static let methodsJSON = """
    {
      "schema_version": 1,
      "default_serve_method": "turboquant_rvq",
      "accounting_only": true,
      "accounting_note": "Compression is accounting-only.",
      "methods": [
        {"name": "turboquant_rvq", "family": "quantization", "serve_tier": "accounting_only",
         "serve_tier_label": "available", "is_servable": true, "blurb": "Default.",
         "config_fields": ["bit_width_inlier", "seed"],
         "field_schema": [{"name": "bit_width_inlier", "type": "int", "optional": false, "default": 2, "help": null},
                          {"name": "svdq_bit_schedule", "type": "tuple", "optional": true,
                           "default": [8, 4, 2], "help": "x"}],
         "coverage": "keys_only", "coverage_label": "partial estimate", "paper_deviation": null,
         "is_adapted": false, "unsupported_reason": null, "docs_url": "https://example.com/rvq",
         "capabilities": {"supported_bits": [1, 2]}},
        {"name": "kivi", "family": "quantization", "serve_tier": "accounting_only",
         "serve_tier_label": "available", "is_servable": true, "blurb": "KIVI.",
         "config_fields": [], "field_schema": [], "coverage": "keys_and_values",
         "coverage_label": "full estimate", "paper_deviation": null, "is_adapted": true,
         "unsupported_reason": null, "docs_url": null},
        {"name": "future", "family": "transfer", "serve_tier": "crashes",
         "serve_tier_label": "not available yet", "is_servable": false, "blurb": "New.",
         "config_fields": [], "field_schema": [], "coverage": "something_new",
         "coverage_label": "?", "paper_deviation": "adapted", "is_adapted": false,
         "unsupported_reason": "no serving contract", "docs_url": null}
      ]
    }
    """

    static let autoConfigJSON = """
    {
      "workload": {"head_dim": 128, "seq_len": 8192, "n_layers": 36, "batch_size": 1},
      "hardware": {"total_memory_bytes": 17179869184, "active_memory_bytes": 0},
      "config": {"method": "kivi", "head_dim": 128, "bit_width_inlier": 2, "kivi_group_size": 32},
      "reason": "memory pressure moderate; kivi 2-bit"
    }
    """

    static func readyLine(host: String = "127.0.0.1", port: Int = 8000, accountingOnly: Bool? = true) -> String {
        let accounting = accountingOnly.map { ", \"accounting_only\": \($0)" } ?? ""
        return "VELOXQUANT_READY {\"schema_version\": 1, \"model\": \"m\", \"method\": \"turboquant_rvq\", "
            + "\"bits\": 2, \"host\": \"\(host)\", \"port\": \(port), \"layer_caches\": 36, "
            + "\"endpoints\": {\"openai_base_url\": \"http://\(host):\(port)/v1\", "
            + "\"chat_completions\": \"http://\(host):\(port)/v1/chat/completions\", "
            + "\"completions\": \"http://\(host):\(port)/v1/completions\", "
            + "\"models\": \"http://\(host):\(port)/v1/models\"}"
            + "\(accounting), \"accounting_note\": \"accounting-only\"}"
    }

    static func chatJSON() -> Data {
        Data((#"{"id":"p","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":" "},"#
            + #""finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#).utf8)
    }

    static let hardware = HardwareInfo(
        chipName: "Apple M3 Pro",
        chipFamily: .m3,
        performanceCoreCount: 6,
        efficiencyCoreCount: 6,
        gpuCoreCount: nil,
        unifiedMemoryBytes: 18 * 1_073_741_824,
        macOSVersion: "macOS 15.0.0"
    )
}
