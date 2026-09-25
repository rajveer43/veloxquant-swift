import XCTest
@testable import VeloxQuantCore
@testable import VeloxQuantRuntime

final class AutoPilotTests: XCTestCase {
    private let wontFitWarning = "A 70B model will not fit in 16 GB. Its weights alone need ~40.0 GB, which is more "
        + "than this Mac has once macOS takes its share — you are about 28.0 GB short of any headroom. "
        + "Pick a smaller model."

    /// A runner answering `recommend`, `methods`, and `auto-config` from fixtures.
    private func runner(recommend: String, methods: String = Fixtures.methodsJSON) -> FakeProcessRunner {
        FakeProcessRunner { call in
            switch call.arguments.dropFirst(2).first {
            case "recommend": return .success(recommend)
            case "methods": return .success(methods)
            case "auto-config": return .success(Fixtures.autoConfigJSON)
            default: return .failure(1, stderr: "unexpected \(call.arguments)")
            }
        }
    }

    private func dependencies(_ runner: FakeProcessRunner, availableGB: UInt64 = 12) -> AutoPilotDependencies {
        AutoPilotDependencies(
            hardware: { Fixtures.hardware },
            hostMemory: { HostMemory(totalBytes: 18 * 1_073_741_824, availableBytes: availableGB * 1_073_741_824) },
            runner: runner
        )
    }

    func testAutoSelectsModelAndBuildsTransparentPlan() async throws {
        let fake = runner(recommend: Fixtures.recommendJSON())
        let outcome = try await AutoPilot.tryStart(
            AutoPilotRequest(model: .auto(task: .coding)),
            pythonEnvironment: Fixtures.python,
            dependencies: dependencies(fake)
        )
        guard case .started(let session) = outcome else {
            return XCTFail("expected .started")
        }
        let plan = session.plan
        XCTAssertEqual(plan.selectedModel.name, "mlx-community/Qwen3-Coder-4bit")
        XCTAssertTrue(plan.selectionReason.contains("memory headroom"))
        XCTAssertEqual(plan.contextLength, 8192)
        XCTAssertEqual(plan.method, "turboquant_rvq")
        XCTAssertEqual(plan.bits, 1)
        XCTAssertFalse(plan.usedServeSafeFallback)
        XCTAssertEqual(plan.safetyMarginBytes, UInt64(Double(12 * 1_073_741_824) * 0.15))
        XCTAssertTrue(plan.accountingOnly)
        XCTAssertTrue(plan.memoryEstimate.accountingOnly)
        XCTAssertGreaterThanOrEqual(plan.decisions.count, 5)
        XCTAssertEqual(
            plan.serveConfig,
            ServeConfig(model: "mlx-community/Qwen3-Coder-4bit", method: "turboquant_rvq", bits: 1)
        )

        // recommend got the real legacy-mode flags derived from the hardware and model.
        XCTAssertEqual(plan.recommendRequest.chip, "M3")
        XCTAssertEqual(plan.recommendRequest.ramGB, 16, "18 GB rounds down to the 16 GB bucket")
        XCTAssertEqual(plan.recommendRequest.modelClass, "14B", "8B rounds up to the 14B class")
        XCTAssertEqual(plan.recommendRequest.layerCount, 36)
        XCTAssertEqual(fake.calls.map { $0.arguments[2] }, ["recommend", "methods"])
    }

    func testWontFitIsReturnedAsDataAndThrownWithIdenticalPayload() async throws {
        let fake = runner(recommend: Fixtures.recommendJSON(warnings: ["Heads up: small model.", wontFitWarning]))
        let request = AutoPilotRequest(model: .named("mlx-community/Qwen3-8B-4bit"))

        let outcome = try await AutoPilot.tryStart(
            request, pythonEnvironment: Fixtures.python, dependencies: dependencies(fake)
        )
        guard case .wontFit(let fitError) = outcome else {
            return XCTFail("expected .wontFit")
        }
        XCTAssertEqual(fitError.warnings, [wontFitWarning], "only the matching warnings are carried")
        XCTAssertTrue(fitError.message.contains("force: true"))

        do {
            _ = try await AutoPilot.start(request, pythonEnvironment: Fixtures.python, dependencies: dependencies(fake))
            XCTFail("expected autopilotWontFit")
        } catch VeloxQuantError.autopilotWontFit(let warnings, let recommendation) {
            XCTAssertEqual(warnings, fitError.warnings)
            XCTAssertEqual(recommendation, fitError.recommendation)
        }
    }

    func testForceProceedsAndRecordsTheOverride() async throws {
        let fake = runner(recommend: Fixtures.recommendJSON(warnings: [wontFitWarning]))
        let session = try await AutoPilot.start(
            AutoPilotRequest(model: .named("mlx-community/Qwen3-8B-4bit"), force: true),
            pythonEnvironment: Fixtures.python,
            dependencies: dependencies(fake)
        )
        XCTAssertEqual(session.plan.wontFitWarnings, [wontFitWarning])
        XCTAssertTrue(session.plan.decisions.contains { $0.contains("overridden by force") })
    }

    func testUnservableRecommendationFallsBackToAutoConfigPool() async throws {
        let fake = runner(recommend: Fixtures.recommendJSON(method: "rabitq"))
        let session = try await AutoPilot.start(
            AutoPilotRequest(model: .named("mlx-community/Qwen3-8B-4bit"), contextLength: 4096),
            pythonEnvironment: Fixtures.python,
            dependencies: dependencies(fake)
        )
        XCTAssertTrue(session.plan.usedServeSafeFallback)
        XCTAssertEqual(session.plan.method, "kivi")
        XCTAssertEqual(session.plan.bits, 2)
        XCTAssertEqual(session.plan.fallbackReason, "memory pressure moderate; kivi 2-bit")
        XCTAssertEqual(session.plan.recommendation.method, "rabitq", "recommend's answer stays visible in the plan")

        let autoConfigCall = try XCTUnwrap(fake.calls.first { $0.arguments[2] == "auto-config" })
        XCTAssertTrue(autoConfigCall.arguments.contains("--total-memory-bytes"))
        let seqLenIndex = try XCTUnwrap(autoConfigCall.arguments.firstIndex(of: "--seq-len"))
        XCTAssertEqual(autoConfigCall.arguments[seqLenIndex + 1], "4096")
    }

    func testUnknownNamedModelThrowsModelNotFound() async {
        do {
            _ = try await AutoPilot.tryStart(
                AutoPilotRequest(model: .named("does-not-exist")),
                pythonEnvironment: Fixtures.python,
                dependencies: dependencies(runner(recommend: Fixtures.recommendJSON()))
            )
            XCTFail("expected modelNotFound")
        } catch VeloxQuantError.modelNotFound(let name) {
            XCTAssertEqual(name, "does-not-exist")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNoModelFittingMemoryThrowsNoModelFits() async {
        do {
            _ = try await AutoPilot.tryStart(
                AutoPilotRequest(model: .auto(task: .vision)),
                pythonEnvironment: Fixtures.python,
                dependencies: dependencies(runner(recommend: Fixtures.recommendJSON()), availableGB: 1)
            )
            XCTFail("expected noModelFits")
        } catch VeloxQuantError.noModelFits(let task, _) {
            XCTAssertEqual(task, "vision")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnrecognizedChipThrowsUnsupportedPlatform() async {
        var deps = dependencies(runner(recommend: Fixtures.recommendJSON()))
        deps.hardware = {
            HardwareInfo(
                chipName: "Intel Core i9", chipFamily: nil, performanceCoreCount: 8, efficiencyCoreCount: 0,
                gpuCoreCount: nil, unifiedMemoryBytes: 32 * 1_073_741_824, macOSVersion: "macOS 13.0.0"
            )
        }
        do {
            _ = try await AutoPilot.tryStart(AutoPilotRequest(model: .named("mlx-community/Qwen3-8B-4bit")),
                                             pythonEnvironment: Fixtures.python, dependencies: deps)
            XCTFail("expected unsupportedPlatform")
        } catch VeloxQuantError.unsupportedPlatform {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCustomModelAndModelClassOverride() async throws {
        let custom = ModelInfo(
            name: "my/model",
            parameters: 3_000_000_000,
            architecture: ModelArchitecture(name: "my/model", layerCount: 28, kvHeadCount: 4, headDimension: 64),
            tasks: [.chat]
        )
        let session = try await AutoPilot.start(
            AutoPilotRequest(model: .custom(custom), goal: .maxContext, modelClass: "7B"),
            pythonEnvironment: Fixtures.python,
            dependencies: dependencies(runner(recommend: Fixtures.recommendJSON()))
        )
        XCTAssertEqual(session.plan.selectedModel, custom)
        XCTAssertEqual(session.plan.recommendRequest.modelClass, "7B")
        XCTAssertEqual(session.plan.recommendRequest.goal, .maxContext)
    }

    func testWontFitPatternMatchesTSRegexCaseInsensitively() {
        XCTAssertTrue(AutoPilot.wontFitPattern(matches: "This WILL NOT FIT anywhere"))
        XCTAssertTrue(AutoPilot.wontFitPattern(matches: "you are 2 GB short of any headroom"))
        XCTAssertFalse(AutoPilot.wontFitPattern(matches: "A 14B model barely fits in 16 GB."))
    }

    func testExtractBitWidthFollowsTSKeyOrder() {
        XCTAssertEqual(AutoPilot.extractBitWidth(["kivi_bits": .int(4), "bit_width_inlier": .int(2)]), 2)
        XCTAssertEqual(AutoPilot.extractBitWidth(["gear_bits": .int(4)]), 4)
        XCTAssertNil(AutoPilot.extractBitWidth(["seed": .int(42)]))
    }

    /// `AutoPilotOutcome` has no `default:` — adding a case must break this at compile time.
    func testOutcomeSwitchIsExhaustive() async throws {
        let outcome = try await AutoPilot.tryStart(
            AutoPilotRequest(model: .named("mlx-community/Qwen3-8B-4bit")),
            pythonEnvironment: Fixtures.python,
            dependencies: dependencies(runner(recommend: Fixtures.recommendJSON()))
        )
        switch outcome {
        case .started(let session): XCTAssertEqual(session.plan.selectedModel.name, "mlx-community/Qwen3-8B-4bit")
        case .wontFit: XCTFail("expected .started")
        }
    }
}
