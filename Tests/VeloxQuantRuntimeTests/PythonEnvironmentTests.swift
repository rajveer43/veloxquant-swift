import XCTest
@testable import VeloxQuantCore
@testable import VeloxQuantRuntime

final class PythonEnvironmentTests: XCTestCase {
    private static let validationArguments = ["-c", "import veloxquant_mlx; print(veloxquant_mlx.__version__)"]

    /// A runner where only `validInterpreters` import veloxquant_mlx, and `$SHELL -l/-i -c
    /// 'command -v python3'` answers with `shellResolves`.
    private func runner(valid validInterpreters: Set<String>, shellResolves: String? = nil) -> FakeProcessRunner {
        FakeProcessRunner { call in
            if call.arguments == Self.validationArguments {
                return validInterpreters.contains(call.executable)
                    ? .success("0.71.1\n")
                    : .failure(1, stderr: "ModuleNotFoundError: No module named 'veloxquant_mlx'")
            }
            if call.arguments.last == "command -v python3", let shellResolves {
                return .success("some banner\n\(shellResolves)\n")
            }
            return .failure(1, stderr: "")
        }
    }

    // MARK: - Go's ResolvePythonInterpreter order

    func testResolveInterpreterPathFollowsGoOrder() {
        let withEnv = ["VELOXQUANT_PYTHON": "/env/python"]
        let explicitWins = PythonEnvironment.resolveInterpreterPath(explicit: "/x/python", environment: withEnv)
        XCTAssertEqual(explicitWins, "/x/python")
        XCTAssertEqual(PythonEnvironment.resolveInterpreterPath(explicit: "", environment: withEnv), "/env/python")
        let emptyEnv = ["VELOXQUANT_PYTHON": ""]
        XCTAssertEqual(PythonEnvironment.resolveInterpreterPath(explicit: nil, environment: emptyEnv), "python3")
        XCTAssertEqual(PythonEnvironment.resolveInterpreterPath(explicit: nil, environment: [:]), "python3")
    }

    // MARK: - validate

    func testValidateReturnsTrimmedVersion() async throws {
        let environment = try await PythonEnvironment.validate(interpreterPath: "/p", runner: runner(valid: ["/p"]))
        XCTAssertEqual(environment, PythonEnvironment(interpreterPath: "/p", veloxquantVersion: "0.71.1"))
    }

    func testValidateThrowsPythonEnvironmentNotFoundWhenImportFails() async {
        do {
            _ = try await PythonEnvironment.validate(interpreterPath: "/p", runner: runner(valid: []))
            XCTFail("expected failure")
        } catch VeloxQuantError.pythonEnvironmentNotFound(let reason) {
            XCTAssertTrue(reason.contains("not importable with /p"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testValidateMapsLaunchFailure() async {
        let failing = FakeProcessRunner { call in
            throw ProcessLaunchError(executable: call.executable, reason: "No such file")
        }
        do {
            _ = try await PythonEnvironment.validate(interpreterPath: "/missing", runner: failing)
            XCTFail("expected failure")
        } catch VeloxQuantError.pythonEnvironmentNotFound(let reason) {
            XCTAssertTrue(reason.contains("could not launch /missing"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - autoDetect order

    func testExplicitOverrideIsTheOnlyCandidateAndFailsLoudly() async {
        let fake = runner(valid: ["/opt/homebrew/bin/python3"])
        do {
            _ = try await PythonEnvironment.autoDetect(
                environment: ["VELOXQUANT_PYTHON": "/broken/python"],
                runner: fake,
                isExecutableFile: { _ in true }
            )
            XCTFail("an invalid explicit override must not be silently skipped")
        } catch VeloxQuantError.pythonEnvironmentNotFound {
            XCTAssertEqual(fake.calls.map(\.executable), ["/broken/python"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testVirtualEnvComesBeforeFixedCandidates() async throws {
        let fake = runner(valid: ["/venv/bin/python3", "/opt/homebrew/bin/python3"])
        let found = try await PythonEnvironment.autoDetect(
            environment: ["VIRTUAL_ENV": "/venv"],
            runner: fake,
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(found.interpreterPath, "/venv/bin/python3")
        XCTAssertEqual(fake.calls.map(\.executable), ["/venv/bin/python3"])
    }

    func testFallsThroughCandidatesInStudioOrder() async throws {
        let fake = runner(valid: ["/usr/bin/python3"])
        let found = try await PythonEnvironment.autoDetect(
            environment: ["CONDA_PREFIX": "/conda"],
            runner: fake,
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(found.interpreterPath, "/usr/bin/python3")
        XCTAssertEqual(fake.calls.map(\.executable), [
            "/conda/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
        ])
    }

    func testLoginShellResolutionThenBarePython3() async throws {
        let shim = "/Users/me/.pyenv/shims/python3"
        let shellFake = runner(valid: [shim], shellResolves: shim)
        let viaShell = try await PythonEnvironment.autoDetect(
            environment: ["SHELL": "/bin/zsh"],
            runner: shellFake,
            isExecutableFile: { _ in false }
        )
        XCTAssertEqual(viaShell.interpreterPath, "/Users/me/.pyenv/shims/python3")
        XCTAssertEqual(shellFake.calls.first?.arguments, ["-l", "-c", "command -v python3"])

        let bareFake = runner(valid: ["python3"])
        let bare = try await PythonEnvironment.autoDetect(
            environment: [:], runner: bareFake, isExecutableFile: { _ in false }
        )
        XCTAssertEqual(bare.interpreterPath, "python3")
        let shellCalls = bareFake.calls.filter { $0.executable == "/bin/zsh" }.map { $0.arguments.first }
        XCTAssertEqual(shellCalls, ["-l", "-i"], "both -l and -i are tried, in that order")
    }

    func testNothingValidatesThrowsWithEveryCandidateListed() async {
        do {
            _ = try await PythonEnvironment.autoDetect(
                environment: [:], runner: runner(valid: []), isExecutableFile: { _ in true }
            )
            XCTFail("expected failure")
        } catch VeloxQuantError.pythonEnvironmentNotFound(let reason) {
            XCTAssertTrue(reason.contains("/opt/homebrew/bin/python3"))
            XCTAssertTrue(reason.contains("python3"))
            XCTAssertTrue(reason.contains("VELOXQUANT_PYTHON"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBareCommandNamesLaunchThroughEnv() {
        let (url, arguments) = FoundationProcessRunner.launchTarget(executable: "python3", arguments: ["-V"])
        XCTAssertEqual(url.path, "/usr/bin/env")
        XCTAssertEqual(arguments, ["python3", "-V"])
        let (pathURL, pathArguments) = FoundationProcessRunner.launchTarget(
            executable: "/usr/bin/python3", arguments: ["-V"]
        )
        XCTAssertEqual(pathURL.path, "/usr/bin/python3")
        XCTAssertEqual(pathArguments, ["-V"])
    }

    func testFoundationRunnerDrainsLargeOutputWithoutDeadlock() async throws {
        // > 64 KiB on stdout: Studio's read-after-exit pattern would block forever here.
        let output = try await FoundationProcessRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "yes a | head -c 300000; echo err >&2; exit 3"]
        )
        XCTAssertEqual(output.exitCode, 3)
        XCTAssertEqual(output.stdout.count, 300_000)
        XCTAssertEqual(output.stderr, "err\n")
    }

    func testFoundationRunnerReportsLaunchFailure() async {
        do {
            _ = try await FoundationProcessRunner().run(executable: "/definitely/not/here", arguments: [])
            XCTFail("expected launch failure")
        } catch is ProcessLaunchError {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
