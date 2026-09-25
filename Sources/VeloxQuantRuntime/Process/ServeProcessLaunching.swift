#if os(macOS)

import Darwin
import Foundation

/// The narrow slice of a long-running child process `VeloxQuantProcess` needs. Distinct from
/// `ProcessRunning`'s run-to-completion model: `serve` stays alive, so tests must be able to
/// feed stdout/stderr lines and simulate exit independently (plan §5.1's `ProcessLaunching`).
public protocol ServeProcessHandle: AnyObject, Sendable {
    /// OS process id.
    var processIdentifier: Int32 { get }
    /// Whether the process is still running.
    var isRunning: Bool { get }
    /// stdout, line by line. Single-consumer; finishes at EOF.
    var stdoutLines: AsyncStream<String> { get }
    /// stderr, line by line. Single-consumer; finishes at EOF.
    var stderrLines: AsyncStream<String> { get }
    /// Waits for exit and returns the exit status, or `nil` if the calling task is cancelled
    /// first (so a readiness race can abandon the wait).
    func waitUntilExit() async -> Int32?
    /// Sends `SIGINT` — the signal `serve.py`/`mlx_lm.server`'s `except KeyboardInterrupt`
    /// cleanup path actually handles.
    func interrupt()
    /// Sends `SIGTERM`.
    func terminate()
    /// Sends `SIGKILL`.
    func kill()
}

/// Launches a long-running process.
public protocol ServeProcessLaunching: Sendable {
    /// Launches `executable` (a path, or a bare name resolved via `PATH`) and returns
    /// immediately with a handle.
    func launch(executable: String, arguments: [String]) throws -> ServeProcessHandle
}

/// `ServeProcessLaunching` backed by `Foundation.Process`, following Studio's
/// `StreamingProcessController`: `Pipe`s whose `readabilityHandler` reads incrementally
/// (non-blocking, no dedicated read thread), and `terminationHandler` for exit.
public struct FoundationServeProcessLauncher: ServeProcessLaunching {
    /// Creates a launcher.
    public init() {}

    /// Launches the process.
    public func launch(executable: String, arguments: [String]) throws -> ServeProcessHandle {
        try FoundationServeProcess(executable: executable, arguments: arguments)
    }
}

/// A `Foundation.Process` wrapped as a `ServeProcessHandle`.
final class FoundationServeProcess: ServeProcessHandle, @unchecked Sendable {
    let stdoutLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>

    private let process = Process()
    private let exitState = ExitState()

    init(executable: String, arguments: [String]) throws {
        let (url, fullArguments) = FoundationProcessRunner.launchTarget(executable: executable, arguments: arguments)
        process.executableURL = url
        process.arguments = fullArguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Bounded buffers: after readiness nobody may consume these streams, but the
        // readability handlers keep draining the pipes (so the child never blocks on a full
        // pipe) and only the newest lines are retained.
        stdoutLines = Self.lineStream(from: stdoutPipe.fileHandleForReading)
        stderrLines = Self.lineStream(from: stderrPipe.fileHandleForReading)

        process.terminationHandler = { [exitState] finished in
            exitState.markExited(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessLaunchError(executable: executable, reason: error.localizedDescription)
        }
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func waitUntilExit() async -> Int32? {
        await exitState.wait()
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let splitter = LineSplitter()
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                if let rest = splitter.flush() { continuation.yield(rest) }
                continuation.finish()
                return
            }
            for line in splitter.append(data) {
                continuation.yield(line)
            }
        }
        return stream
    }
}

/// Accumulates bytes and splits them into `\n`-terminated lines (`\r\n` tolerated), decoding
/// only complete lines so a multi-byte UTF-8 sequence split across reads is never corrupted.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            // Non-failable on purpose (invalid bytes become U+FFFD): one bad byte in a log line
            // must not drop the line — same reasoning as `AsyncByteLines.swift`.
            // swiftlint:disable:next optional_data_string_conversion
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Exit status plus cancellable waiters. Shared by the real process and test fakes.
public final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]

    /// Creates an un-exited state.
    public init() {}

    /// The exit status, once exited.
    public var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Records exit and wakes every waiter. Later calls are ignored.
    public func markExited(_ code: Int32) {
        lock.lock()
        guard status == nil else {
            lock.unlock()
            return
        }
        status = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values {
            waiter.resume(returning: code)
        }
    }

    /// Waits for exit; returns `nil` if the calling task is cancelled first.
    public func wait() async -> Int32? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(returning: nil)
        }
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
