#if os(macOS)

import Foundation

/// Captured result of a one-shot subprocess run.
public struct ProcessOutput: Sendable, Equatable {
    /// The process's exit status.
    public let exitCode: Int32
    /// Everything written to stdout, decoded as UTF-8.
    public let stdout: String
    /// Everything written to stderr, decoded as UTF-8.
    public let stderr: String

    /// Creates a captured result (tests construct these directly).
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The executable could not be launched at all (missing file, not executable, ...).
public struct ProcessLaunchError: Error, LocalizedError, Sendable, Equatable {
    /// What was being launched.
    public let executable: String
    /// Why launching failed.
    public let reason: String

    /// Human-readable description.
    public var errorDescription: String? {
        "Failed to launch \(executable): \(reason)"
    }
}

/// Mockable boundary around one-shot subprocess execution (plan §5.1). Production code uses
/// `FoundationProcessRunner`; tests substitute a fake that returns canned output, so CLI
/// argument building, JSON decoding, and interpreter-resolution order are verified without a
/// real Python install.
public protocol ProcessRunning: Sendable {
    /// Runs `executable` with `arguments` to completion and returns its captured output.
    /// `executable` is either a path or a bare command name resolved via `PATH`.
    func run(executable: String, arguments: [String]) async throws -> ProcessOutput
}

/// `ProcessRunning` backed by `Foundation.Process` + `Pipe` — Studio's `ProcessRunner` pattern
/// (`VeloxQuant-Studio/VeloxQuantStudio/Support/ProcessRunner.swift`), with two deliberate fixes:
///
/// 1. stdout/stderr are drained **concurrently while the process runs**, not after
///    `waitUntilExit()`. Studio reads both pipes only after exit, which deadlocks as soon as a
///    child writes more than the pipe buffer (~64 KiB) — well within reach of
///    `methods --json`, whose per-method `field_schema`/`capabilities` payload is large.
/// 2. Exit is observed via `terminationHandler` instead of a blocking `waitUntilExit()` on a
///    cooperative-pool thread, and cancelling the calling task terminates the child.
///
/// A bare command name (no `/`, e.g. Go's `"python3"` fallback) is resolved through
/// `/usr/bin/env`, the equivalent of Go's `exec.Command` `PATH` lookup.
public struct FoundationProcessRunner: ProcessRunning {
    /// Creates a runner.
    public init() {}

    /// Runs the process, draining its output concurrently.
    public func run(executable: String, arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        let (url, fullArguments) = Self.launchTarget(executable: executable, arguments: arguments)
        process.executableURL = url
        process.arguments = fullArguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let collected = CollectedOutput()
                let group = DispatchGroup()
                // Entered before launch so a child that exits instantly cannot fire `notify`
                // before both pipes have been drained to EOF.
                group.enter()
                group.enter()

                process.terminationHandler = { finished in
                    group.notify(queue: .global()) {
                        continuation.resume(returning: ProcessOutput(
                            exitCode: finished.terminationStatus,
                            stdout: collected.stdout,
                            stderr: collected.stderr
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessLaunchError(
                        executable: executable,
                        reason: error.localizedDescription
                    ))
                    return
                }

                DispatchQueue.global().async {
                    collected.stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global().async {
                    collected.stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Maps a bare command name onto `/usr/bin/env <name>`; paths are used as-is.
    static func launchTarget(executable: String, arguments: [String]) -> (URL, [String]) {
        if executable.contains("/") {
            return (URL(fileURLWithPath: executable), arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [executable] + arguments)
    }
}

/// Output buffers filled from two reader threads; each field is written exactly once before
/// the dispatch group's `notify` reads it, so the group provides the needed happens-before.
private final class CollectedOutput: @unchecked Sendable {
    var stdoutData = Data()
    var stderrData = Data()

    var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
    var stderr: String { String(data: stderrData, encoding: .utf8) ?? "" }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
