import Foundation

/// The full VeloxQuant SDK error hierarchy. The original 11 cases were defined together in
/// Phase 1; four more (`cliCommandFailed`, `malformedCLIOutput`, `modelNotFound`,
/// `noModelFits`) were added with the CLI/AutoPilot layer, because no Phase 1 case described
/// those failures honestly (see CHANGELOG "Changed"). Exhaustive `switch`es must add them.
///
/// `enum: Error, LocalizedError` mirrors the already-established convention in this exact
/// codebase (`VeloxQuant-Studio/.../ModelService.swift`'s `ServiceError` is precisely this
/// shape), not a fresh design imported from Kotlin.
///
/// Unlike Kotlin's sibling SDK, `autopilotWontFit` carries `recommendation: Recommendation`
/// directly rather than flattened primitive fields — `VeloxQuantError` and `Recommendation`
/// both live in `VeloxQuantCore`, so this package's two-target shape never creates the
/// cross-module circular-dependency problem that forced Kotlin's flattening correction. Do not
/// "fix" this by analogy with Kotlin; it would be solving a problem Swift doesn't have.
public enum VeloxQuantError: Error, LocalizedError, Sendable {
    /// The HTTP server is not reachable at all (connection refused, DNS failure, timeout).
    case runtimeUnreachable(baseURL: URL, underlying: Error)

    /// A 404 whose body parsed as `{"error": ...}` JSON — a generation failure, not a wrong
    /// route (investigation §1.8: `mlx_lm`'s server returns 404 for generation errors).
    case generationFailed(serverMessage: String)

    /// A 404 whose body was the literal plain-text "Not Found" — a genuinely wrong path.
    case unexpectedRoute(path: String)

    /// A non-2xx response whose body didn't parse as `{"error": ...}` at all — covers the
    /// unhandled `ValueError` / raw internal-error case from investigation §1.2/§1.8.
    case malformedErrorResponse(statusCode: Int, rawBody: String)

    /// A non-404, non-2xx response with a parseable `{"error": ...}` body.
    case serverError(statusCode: Int, message: String)

    /// AutoPilot determined the requested workload likely won't fit. Mirrors
    /// `AutoPilotOutcome.wontFit`'s `AutopilotFitError` payload exactly — the two must never
    /// drift apart in the fields they carry.
    case autopilotWontFit(warnings: [String], recommendation: Recommendation)

    /// `VeloxQuantRuntime` tried to shell out but no working Python interpreter with
    /// `veloxquant_mlx` importable could be found.
    case pythonEnvironmentNotFound(reason: String)

    /// A macOS-only API (process management, hardware detection, AutoPilot) was called on an
    /// unsupported platform. In practice unreachable at compile time given the target split
    /// (VeloxQuantRuntime is excluded from non-macOS builds entirely), but retained for any
    /// future shared-code path that could reach a platform check at runtime.
    case unsupportedPlatform(feature: String, platform: String)

    /// Structured-output response failed to deserialize into the requested type. Note:
    /// `chatStructured()` itself does NOT throw this — it returns `StructuredResult.
    /// parseFailed` instead. Exists for lower-level callers who bypass the sealed-result API.
    case malformedStructuredOutput(raw: String, underlying: Error)

    /// The serve process failed to become ready within the configured timeout.
    case serveStartupTimeout(model: String, port: Int, timeout: Duration)

    /// The serve process exited (`validate_method` failure, crash, etc.) before or during
    /// startup.
    case serveProcessExited(exitCode: Int32, stderr: String)

    /// A one-shot `python -m veloxquant_mlx <subcommand>` shell-out exited non-zero. Added with
    /// `VeloxQuantRuntime`'s CLI layer — the direct analogue of Kotlin's `CliCommandFailed`.
    case cliCommandFailed(command: String, exitCode: Int32, stderr: String)

    /// A CLI shell-out exited 0 but its `--json` stdout did not decode into the expected shape
    /// (e.g. a newer `veloxquant_mlx` changed its output schema).
    case malformedCLIOutput(command: String, raw: String, underlying: Error)

    /// AutoPilot was asked for a specific model its registry does not know (Go's
    /// `ErrModelNotFound`).
    case modelNotFound(name: String)

    /// AutoPilot found no registry model for the task whose footprint fits available memory
    /// (Go's `ErrInsufficientMemory`).
    case noModelFits(task: String?, availableMemoryBytes: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .runtimeUnreachable(baseURL, underlying):
            return "VeloxQuant runtime unreachable at \(baseURL.absoluteString): \(underlying.localizedDescription)"
        case let .generationFailed(serverMessage):
            return "Generation failed: \(serverMessage)"
        case let .unexpectedRoute(path):
            return "Unexpected route: \(path) does not exist on this server."
        case let .malformedErrorResponse(statusCode, rawBody):
            return "Malformed error response (HTTP \(statusCode)): \(rawBody)"
        case let .serverError(statusCode, message):
            return "Server error (HTTP \(statusCode)): \(message)"
        case let .autopilotWontFit(warnings, recommendation):
            return "AutoPilot determined \(recommendation.method) likely won't fit: \(warnings.joined(separator: "; "))"
        case let .pythonEnvironmentNotFound(reason):
            return "No usable Python environment found: \(reason)"
        case let .unsupportedPlatform(feature, platform):
            return "\(feature) is not supported on \(platform)."
        case let .malformedStructuredOutput(raw, underlying):
            return "Structured output failed to parse (\(underlying.localizedDescription)): \(raw)"
        case let .serveStartupTimeout(model, port, timeout):
            return "veloxquant serve did not become ready for \(model) on port \(port) within \(timeout)."
        case let .serveProcessExited(exitCode, stderr):
            return "veloxquant serve exited (code \(exitCode)) before becoming ready: \(stderr)"
        case let .cliCommandFailed(command, exitCode, stderr):
            return "`\(command)` failed (exit code \(exitCode)): \(stderr)"
        case let .malformedCLIOutput(command, raw, underlying):
            return "`\(command)` produced output that could not be decoded (\(underlying.localizedDescription)): \(raw)"
        case let .modelNotFound(name):
            return "Model not found in the AutoPilot registry: \(name)"
        case let .noModelFits(task, availableMemoryBytes):
            let gib = String(format: "%.1f", Double(availableMemoryBytes) / 1_073_741_824)
            return "No model fits available memory (\(gib) GiB) for task \"\(task ?? "")\"."
        }
    }
}
