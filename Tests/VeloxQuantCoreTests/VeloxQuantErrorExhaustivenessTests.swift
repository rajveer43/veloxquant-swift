import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VeloxQuantCore

/// Verifies an exhaustive `switch` over `VeloxQuantError` compiles with no `default:`/`case _:`
/// branch — Swift's compiler gives this exhaustiveness check for free (investigation §5.4).
/// If a new `VeloxQuantError` case is ever added without updating this `switch`, this file
/// fails to *compile*, not merely fails a test — the strongest form of the guarantee.
final class VeloxQuantErrorExhaustivenessTests: XCTestCase {
    private static let baseURL = URL(string: "http://127.0.0.1:8000")

    // One branch per VeloxQuantError case, by design.
    // swiftlint:disable:next cyclomatic_complexity
    private func exhaustiveSwitch(over error: VeloxQuantError) {
        switch error {
        case .runtimeUnreachable: break
        case .generationFailed: break
        case .unexpectedRoute: break
        case .malformedErrorResponse: break
        case .serverError: break
        case .autopilotWontFit: break
        case .pythonEnvironmentNotFound: break
        case .unsupportedPlatform: break
        case .malformedStructuredOutput: break
        case .serveStartupTimeout: break
        case .serveProcessExited: break
        }
    }

    func testSwitchIsExhaustiveWithNoDefaultBranch() throws {
        let baseURL = try XCTUnwrap(Self.baseURL)
        let errors: [VeloxQuantError] = [
            .runtimeUnreachable(baseURL: baseURL, underlying: URLError(.unknown)),
            .generationFailed(serverMessage: "x"),
            .unexpectedRoute(path: "/nope"),
            .malformedErrorResponse(statusCode: 500, rawBody: "x"),
            .serverError(statusCode: 500, message: "x"),
            .pythonEnvironmentNotFound(reason: "x"),
            .unsupportedPlatform(feature: "x", platform: "x"),
            .malformedStructuredOutput(raw: "x", underlying: URLError(.unknown)),
            .serveStartupTimeout(model: "x", port: 8000, timeout: .seconds(1)),
            .serveProcessExited(exitCode: 1, stderr: "x")
        ]

        for error in errors {
            exhaustiveSwitch(over: error)
            XCTAssertNotNil(error.errorDescription)
        }
    }
}
