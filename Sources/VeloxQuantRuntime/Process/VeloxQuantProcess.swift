#if os(macOS)

import Darwin
import Foundation
import VeloxQuantCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A running `python -m veloxquant_mlx serve` process: launch, readiness, and clean shutdown.
///
/// Behavior draws on all three sibling references (see CHANGELOG):
///
/// - **Launch/handshake** — Go's `runtime.StartProcess` and Kotlin's `VeloxQuantProcess`:
///   `start` returns only once the `VELOXQUANT_READY {...}` stdout handshake is parsed; the
///   handshake's host/port become `baseURL` (Go updates its URL from the handshake the same
///   way), and `client` is pre-wired to it.
/// - **Readiness race** — Kotlin's fix for Go's confirmed hang: `mlx_lm.server` loads the model
///   lazily on the first request, and `serve` only prints the handshake from inside that load,
///   so waiting on stdout alone (Go) can hang for the full timeout on a healthy server. `start`
///   therefore also polls `GET /health` and, once the port answers, sends a `max_tokens: 1`
///   priming chat request (retrying with backoff). The priming response is ignored — the
///   handshake stays the only readiness signal.
/// - **Failure modes** — exit before readiness throws `VeloxQuantError.serveProcessExited` with
///   captured stderr (`validate_method`'s fail-fast path); no handshake within
///   `ServeConfig.readyTimeout` stops the process and throws `.serveStartupTimeout`.
/// - **Shutdown** — Studio's `StreamingProcessController.stop()` signal order (`SIGINT`, then
///   `SIGTERM`), with Go's final `SIGKILL` escalation added (see `stop(gracePeriod:)`).
///
/// **Orphan cleanup is best-effort, not guaranteed** (plan §9 item 5, non-goal 12). Every live
/// process is registered with a process-wide `atexit` hook that sends `SIGINT` on normal exit
/// of the host program, and `deinit` sends `SIGINT` if the process is still running. Neither
/// runs on a crash, `SIGKILL`, or force-quit. A macOS **app** should also observe
/// `NSApplication.willTerminateNotification` and call `stop()` explicitly.
public actor VeloxQuantProcess {
    /// Lifecycle state (plan §3.5).
    public enum State: Sendable, Equatable {
        /// Not started (never observed on an instance returned by `start`).
        case idle
        /// Launching and waiting for the handshake (never observed on a returned instance).
        case starting
        /// Ready and serving.
        case running
        /// Exited with this status (after `stop()` or on its own).
        case finished(exitCode: Int32)
        /// Failed.
        case failed(reason: String)
    }

    /// Current lifecycle state.
    public private(set) var state: State = .running

    /// The configuration this process was launched with.
    public nonisolated let config: ServeConfig
    /// The parsed readiness handshake.
    public nonisolated let readyPayload: ServeReadyPayload
    /// Where the server is listening, from the handshake.
    public nonisolated let baseURL: URL
    /// A client pre-wired to `baseURL` — never reconstruct one by hand.
    public nonisolated let client: VeloxQuantClient

    private nonisolated let handle: ServeProcessHandle
    private nonisolated let stderrBuffer: LineRingBuffer

    /// The child's OS process id.
    public nonisolated var processIdentifier: Int32 { handle.processIdentifier }

    /// The most recent stderr lines (bounded), for diagnostics.
    public nonisolated var recentStderr: [String] { stderrBuffer.lines }

    private init(
        config: ServeConfig,
        readyPayload: ServeReadyPayload,
        baseURL: URL,
        client: VeloxQuantClient,
        handle: ServeProcessHandle,
        stderrBuffer: LineRingBuffer
    ) {
        self.config = config
        self.readyPayload = readyPayload
        self.baseURL = baseURL
        self.client = client
        self.handle = handle
        self.stderrBuffer = stderrBuffer
    }

    deinit {
        // Best-effort orphan prevention; see the type's doc comment.
        if handle.isRunning {
            handle.interrupt()
        }
        LiveServeProcesses.shared.remove(handle.processIdentifier)
    }

    // MARK: - Start

    /// Launches `serve` for `config` under `pythonEnvironment` and returns once it is ready.
    ///
    /// - Parameters:
    ///   - launcher: process-launching boundary (injectable for tests).
    ///   - session: `URLSession` for the health poll, the priming request, and `client`.
    /// - Throws: `VeloxQuantError.serveProcessExited`, `.serveStartupTimeout`,
    ///   `.pythonEnvironmentNotFound` (interpreter could not be launched), or
    ///   `.malformedCLIOutput` (a handshake line whose JSON did not decode).
    public static func start(
        config: ServeConfig,
        pythonEnvironment: PythonEnvironment,
        launcher: ServeProcessLaunching = FoundationServeProcessLauncher(),
        session: URLSession = .shared
    ) async throws -> VeloxQuantProcess {
        let invocation = pythonEnvironment.invocation(ServeConfig.serveArguments(for: config))
        let handle: ServeProcessHandle
        do {
            handle = try launcher.launch(executable: invocation.executable, arguments: invocation.arguments)
        } catch {
            throw VeloxQuantError.pythonEnvironmentNotFound(reason: error.localizedDescription)
        }
        LiveServeProcesses.shared.insert(handle.processIdentifier)

        let stderrBuffer = LineRingBuffer(capacity: 200)
        let stderrDrain = Task {
            for await line in handle.stderrLines {
                stderrBuffer.append(line)
            }
        }

        let payload: ServeReadyPayload
        do {
            payload = try await awaitReadiness(config: config, handle: handle, session: session)
        } catch let failure as ReadinessFailure {
            let error = await resolve(
                failure, config: config, handle: handle, stderrDrain: stderrDrain, stderr: stderrBuffer
            )
            LiveServeProcesses.shared.remove(handle.processIdentifier)
            throw error
        } catch {
            await forceStop(handle)
            LiveServeProcesses.shared.remove(handle.processIdentifier)
            throw error
        }

        guard let baseURL = Self.baseURL(host: payload.host, port: payload.port) else {
            await forceStop(handle)
            LiveServeProcesses.shared.remove(handle.processIdentifier)
            throw VeloxQuantError.malformedCLIOutput(
                command: "veloxquant_mlx serve",
                raw: "host=\(payload.host) port=\(payload.port)",
                underlying: URLError(.badURL)
            )
        }
        let process = VeloxQuantProcess(
            config: config,
            readyPayload: payload,
            baseURL: baseURL,
            client: VeloxQuantClient(baseURL: baseURL, defaultModel: payload.model, session: session),
            handle: handle,
            stderrBuffer: stderrBuffer
        )
        await process.watchForExit()
        return process
    }

    // MARK: - Lifecycle

    /// Stops the process: `SIGINT`, wait up to `gracePeriod` for a clean exit, then `SIGTERM`,
    /// then (after 2 more seconds) `SIGKILL`. Idempotent.
    ///
    /// Studio's `stop()` always sleeps the full grace period before checking; this returns as
    /// soon as the process exits. The final `SIGKILL` is Go's `Process.Stop` escalation — Studio
    /// and the plan stop at `SIGTERM`, which a wedged Python process can ignore.
    public func stop(gracePeriod: Duration = .seconds(10)) async {
        if case .finished = state { return }
        if handle.isRunning {
            handle.interrupt()
            if await !Self.waitForExit(handle, timeout: gracePeriod) {
                handle.terminate()
                if await !Self.waitForExit(handle, timeout: .seconds(2)) {
                    handle.kill()
                }
            }
        }
        let code = await handle.waitUntilExit() ?? -1
        state = .finished(exitCode: code)
        LiveServeProcesses.shared.remove(handle.processIdentifier)
    }

    /// Waits for the process to exit on its own and returns its status.
    public func waitUntilExit() async -> Int32? {
        await handle.waitUntilExit()
    }

    /// A `Monitor` sampling this process's resident memory (and host memory) every `interval`,
    /// plus live per-request metrics from `client` — the plan's (§3.11) process-scoped overload,
    /// the only context in which `Metrics.residentMemoryBytes` is populated.
    public nonisolated func monitor(interval: Duration = Monitor.defaultInterval) -> Monitor {
        client.monitor(interval: interval, sampler: ProcessMetricsSampler(processIdentifier: processIdentifier))
    }

    private func watchForExit() {
        Task { [weak self, handle] in
            guard let code = await handle.waitUntilExit() else { return }
            await self?.markExited(code)
        }
    }

    private func markExited(_ code: Int32) {
        LiveServeProcesses.shared.remove(handle.processIdentifier)
        if case .running = state {
            state = .finished(exitCode: code)
        }
    }

    // MARK: - Readiness race

    enum ReadinessFailure: Error {
        case exited(Int32)
        case timedOut
    }

    private enum ReadinessEvent: Sendable {
        case ready(ServeReadyPayload)
        case exited(Int32)
        case timedOut
        case ignorable
    }

    /// Races the handshake scan, the exit watcher, the priming task, and the timeout.
    static func awaitReadiness(
        config: ServeConfig,
        handle: ServeProcessHandle,
        session: URLSession
    ) async throws -> ServeReadyPayload {
        try await withThrowingTaskGroup(of: ReadinessEvent.self) { group in
            group.addTask {
                for await line in handle.stdoutLines {
                    do {
                        if let payload = try ServeReadyPayload.parse(line: line) {
                            return .ready(payload)
                        }
                    } catch {
                        throw VeloxQuantError.malformedCLIOutput(
                            command: "veloxquant_mlx serve",
                            raw: line,
                            underlying: error
                        )
                    }
                }
                // stdout closed without a handshake; the exit watcher reports why.
                return .ignorable
            }
            group.addTask {
                guard let code = await handle.waitUntilExit() else { return .ignorable }
                return .exited(code)
            }
            group.addTask {
                await prime(host: config.host, port: config.port, session: session, timeout: config.readyTimeout)
                return .ignorable
            }
            group.addTask {
                try await Task.sleep(for: config.readyTimeout)
                return .timedOut
            }

            defer { group.cancelAll() }
            while let event = try await group.next() {
                switch event {
                case .ready(let payload): return payload
                case .exited(let code): throw ReadinessFailure.exited(code)
                case .timedOut: throw ReadinessFailure.timedOut
                case .ignorable: continue
                }
            }
            throw ReadinessFailure.timedOut
        }
    }

    /// Forces `mlx_lm.server`'s lazy model load: poll `GET /health` until the port answers, then
    /// send a `max_tokens: 1` chat request, retrying with backoff until one gets any HTTP
    /// response. Its result is deliberately ignored.
    static func prime(host: String, port: Int, session: URLSession, timeout: Duration) async {
        guard let baseURL = baseURL(host: host, port: port) else { return }
        let healthURL = baseURL.appendingPathComponent("health")
        var delay: Duration = .milliseconds(100)
        func backOff() async -> Bool {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
            delay = min(delay * 2, .seconds(2))
            return true
        }

        while !Task.isCancelled {
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                break
            }
            guard await backOff() else { return }
        }

        let seconds = Double(timeout.components.seconds)
        let primingClient = VeloxQuantClient(baseURL: baseURL, session: session, requestTimeout: max(seconds, 30))
        delay = .milliseconds(100)
        while !Task.isCancelled {
            do {
                _ = try await primingClient.chat(ChatRequest(messages: [.user(" ")], maxTokens: 1))
                return
            } catch VeloxQuantError.runtimeUnreachable {
                guard await backOff() else { return }
            } catch {
                // Any HTTP-level answer means the request reached mlx_lm and triggered the load.
                return
            }
        }
    }

    // MARK: - Helpers

    private static func resolve(
        _ failure: ReadinessFailure,
        config: ServeConfig,
        handle: ServeProcessHandle,
        stderrDrain: Task<Void, Never>,
        stderr: LineRingBuffer
    ) async -> VeloxQuantError {
        switch failure {
        case .exited(let code):
            // Let stderr reach EOF (it does promptly once the child is gone) so the error
            // carries the child's own explanation, e.g. validate_method's message.
            _ = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await stderrDrain.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            return .serveProcessExited(exitCode: code, stderr: stderr.lines.joined(separator: "\n"))
        case .timedOut:
            await forceStop(handle)
            return .serveStartupTimeout(model: config.model, port: config.port, timeout: config.readyTimeout)
        }
    }

    private static func forceStop(_ handle: ServeProcessHandle) async {
        guard handle.isRunning else { return }
        handle.interrupt()
        if await !waitForExit(handle, timeout: .seconds(2)) {
            handle.terminate()
            if await !waitForExit(handle, timeout: .seconds(2)) {
                handle.kill()
            }
        }
    }

    /// Whether `handle` exits within `timeout`.
    static func waitForExit(_ handle: ServeProcessHandle, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await handle.waitUntilExit() != nil }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let exited = await group.next() ?? false
            group.cancelAll()
            return exited
        }
    }

    /// `http://host:port`, connecting to loopback when the server bound every interface;
    /// `nil` only for a host that cannot form a URL.
    static func baseURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = (host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host
        components.port = port
        return components.url
    }
}

/// Fixed-capacity, thread-safe buffer of the most recent lines.
final class LineRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Process-wide registry of live `serve` PIDs, with a one-time `atexit` hook that sends
/// `SIGINT` to each on normal exit of the host program. Best-effort only (see
/// `VeloxQuantProcess`'s doc comment) — the closest Swift analogue of Kotlin's JVM shutdown hook.
final class LiveServeProcesses: @unchecked Sendable {
    static let shared = LiveServeProcesses()

    private let lock = NSLock()
    private var pids: Set<Int32> = []
    private var hookInstalled = false

    func insert(_ pid: Int32) {
        lock.lock()
        pids.insert(pid)
        let needsHook = !hookInstalled
        hookInstalled = true
        lock.unlock()
        if needsHook {
            atexit {
                LiveServeProcesses.shared.interruptAll()
            }
        }
    }

    func remove(_ pid: Int32) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    var livePIDs: Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }

    func interruptAll() {
        for pid in livePIDs where pid > 0 {
            Darwin.kill(pid, SIGINT)
        }
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
