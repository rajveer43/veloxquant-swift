#if os(macOS)

import Foundation
import VeloxQuantCore

/// A validated Python interpreter with `veloxquant_mlx` importable. Every CLI shell-out in
/// `VeloxQuantRuntime` (`VeloxQuantCLI`, `AutoPilot`, `VeloxQuantProcess`) runs
/// `<interpreterPath> -m veloxquant_mlx <subcommand> ...` through one of these — Studio's
/// invocation style (plan §3.13), not a separately-installed `veloxquant` console script.
///
/// Resolution combines both sibling precedents (see CHANGELOG "Changed"):
///
/// - Go's `models.ResolvePythonInterpreter` order (`explicit`, then `$VELOXQUANT_PYTHON`, then
///   `python3`) — the cross-SDK contract, so a `VELOXQUANT_PYTHON` set for the Go/TS SDKs also
///   works here — is available verbatim as `resolveInterpreterPath(explicit:environment:)`.
/// - `autoDetect(...)` honors that same explicit/`VELOXQUANT_PYTHON` override first, then falls
///   through Studio's `PythonEnvironmentService.autoDetect()` candidates (`$VIRTUAL_ENV`,
///   `$CONDA_PREFIX`, fixed Homebrew/`/usr/local`/`/usr/bin` paths, a login-shell
///   `command -v python3` via `-l` then `-i`) before ending on Go's bare `python3`. Unlike
///   Go (which returns a path without checking it), every candidate is validated by actually
///   importing `veloxquant_mlx`, Studio's validation strategy verbatim.
public struct PythonEnvironment: Sendable, Equatable, Hashable {
    /// Path to (or bare `PATH`-resolved name of) the interpreter.
    public let interpreterPath: String
    /// `veloxquant_mlx.__version__` as reported by the interpreter.
    public let veloxquantVersion: String

    /// The environment variable the Go and TS SDKs read for an interpreter override.
    public static let environmentVariable = "VELOXQUANT_PYTHON"

    /// Studio's fixed candidate list (`PythonEnvironmentService.candidatePaths`), in order.
    public static let candidatePaths = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    ]

    /// Wraps an interpreter you have already validated yourself. Prefer `validate(...)`.
    public init(interpreterPath: String, veloxquantVersion: String) {
        self.interpreterPath = interpreterPath
        self.veloxquantVersion = veloxquantVersion
    }

    /// Go's `ResolvePythonInterpreter`, verbatim: `explicit` if non-empty, else
    /// `$VELOXQUANT_PYTHON` if non-empty, else `"python3"`. Pure; does not validate.
    public static func resolveInterpreterPath(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let fromEnvironment = environment[environmentVariable], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return "python3"
    }

    /// Runs `<interpreterPath> -c "import veloxquant_mlx; print(veloxquant_mlx.__version__)"`
    /// and accepts the interpreter only if it exits 0 (Studio's `validate(path:)`, verbatim).
    ///
    /// - Throws: `VeloxQuantError.pythonEnvironmentNotFound` if it cannot be launched or
    ///   `veloxquant_mlx` is not importable.
    public static func validate(
        interpreterPath: String,
        runner: ProcessRunning = FoundationProcessRunner()
    ) async throws -> PythonEnvironment {
        let output: ProcessOutput
        do {
            output = try await runner.run(
                executable: interpreterPath,
                arguments: ["-c", "import veloxquant_mlx; print(veloxquant_mlx.__version__)"]
            )
        } catch {
            throw VeloxQuantError.pythonEnvironmentNotFound(
                reason: "could not launch \(interpreterPath): \(error.localizedDescription)"
            )
        }
        guard output.exitCode == 0 else {
            throw VeloxQuantError.pythonEnvironmentNotFound(
                reason: "veloxquant_mlx is not importable with \(interpreterPath).\n\(output.stderr)"
            )
        }
        return PythonEnvironment(
            interpreterPath: interpreterPath,
            veloxquantVersion: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Finds and validates an interpreter.
    ///
    /// If `explicit` or `$VELOXQUANT_PYTHON` is set, only that interpreter is tried — an
    /// explicit override that fails validation throws rather than being silently skipped.
    /// Otherwise candidates are tried in order: `$VIRTUAL_ENV/bin/python3`,
    /// `$CONDA_PREFIX/bin/python3`, `candidatePaths`, `$SHELL -l -c 'command -v python3'`, then
    /// `-i` (venv/conda activation usually lives in `.zshrc`, which only `-i` reads — Studio's
    /// documented reasoning), then bare `python3` (Go's fallback).
    ///
    /// - Throws: `VeloxQuantError.pythonEnvironmentNotFound` when nothing validates.
    public static func autoDetect(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: ProcessRunning = FoundationProcessRunner(),
        isExecutableFile: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async throws -> PythonEnvironment {
        let override = (explicit?.isEmpty == false) ? explicit : environment[environmentVariable]
        if let override, !override.isEmpty {
            return try await validate(interpreterPath: override, runner: runner)
        }

        var tried: [String] = []
        func attempt(_ path: String) async -> PythonEnvironment? {
            guard !tried.contains(path) else { return nil }
            tried.append(path)
            return try? await validate(interpreterPath: path, runner: runner)
        }

        for prefix in [environment["VIRTUAL_ENV"], environment["CONDA_PREFIX"]].compactMap({ $0 }) {
            let path = (prefix as NSString).appendingPathComponent("bin/python3")
            if isExecutableFile(path), let found = await attempt(path) {
                return found
            }
        }

        for path in candidatePaths where isExecutableFile(path) {
            if let found = await attempt(path) {
                return found
            }
        }

        let shell = environment["SHELL"] ?? "/bin/zsh"
        for flags in [["-l", "-c"], ["-i", "-c"]] {
            if let resolved = await resolveViaShell(shell, flags: flags, runner: runner),
               let found = await attempt(resolved) {
                return found
            }
        }

        if let found = await attempt("python3") {
            return found
        }

        throw VeloxQuantError.pythonEnvironmentNotFound(
            reason: "No Python interpreter with veloxquant_mlx installed was found. Tried: "
                + (tried.isEmpty ? "(no candidates)" : tried.joined(separator: ", "))
                + ". Set \(environmentVariable) to an interpreter with VeloxQuant-MLX installed."
        )
    }

    /// The `[interpreter, "-m", "veloxquant_mlx", subcommand] + arguments` launch this
    /// environment uses for a CLI subcommand.
    func invocation(_ subcommandArguments: [String]) -> (executable: String, arguments: [String]) {
        (interpreterPath, ["-m", "veloxquant_mlx"] + subcommandArguments)
    }

    private static func resolveViaShell(_ shell: String, flags: [String], runner: ProcessRunning) async -> String? {
        guard let output = try? await runner.run(executable: shell, arguments: flags + ["command -v python3"]),
              output.exitCode == 0
        else { return nil }
        // An interactive shell may print banners; the resolved path is the last non-empty line.
        let path = output.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
