import XCTest
@testable import VeloxQuantCore
@testable import VeloxQuantRuntime

final class VeloxQuantCLITests: XCTestCase {
    // MARK: - Argument builders (flag spelling checked against veloxquant_mlx/cli/*.py)

    func testRecommendArgumentsUseKebabCaseAndAllRequiredLegacyFlags() {
        let arguments = VeloxQuantCLI.recommendArguments(for: RecommendCLIRequest(
            chip: "M3", ramGB: 16, modelClass: "14B", goal: .maxContext,
            sequenceLength: 8192, layerCount: 36, kvHeadCount: 8, headDimension: 128
        ))
        XCTAssertEqual(arguments, [
            "recommend", "--chip", "M3", "--ram-gb", "16", "--model-class", "14B", "--goal", "max_context",
            "--seq-len", "8192", "--n-layers", "36", "--n-kv-heads", "8", "--head-dim", "128", "--json"
        ])
    }

    func testAutoConfigArgumentsOnlySendActiveMemoryAlongsideTotal() {
        XCTAssertEqual(
            VeloxQuantCLI.autoConfigArguments(for: AutoConfigCLIRequest(activeMemoryBytes: 5)),
            ["auto-config", "--head-dim", "128", "--seq-len", "4096", "--n-layers", "1", "--batch-size", "1", "--json"]
        )
        XCTAssertEqual(
            VeloxQuantCLI.autoConfigArguments(
                for: AutoConfigCLIRequest(totalMemoryBytes: 100, activeMemoryBytes: 5)
            ).suffix(5),
            ["--total-memory-bytes", "100", "--active-memory-bytes", "5", "--json"]
        )
    }

    func testMethodsArguments() {
        XCTAssertEqual(VeloxQuantCLI.methodsArguments(), ["methods", "--json"])
        XCTAssertEqual(
            VeloxQuantCLI.methodsArguments(servableOnly: true, family: .eviction),
            ["methods", "--json", "--servable-only", "--family", "eviction"]
        )
        XCTAssertEqual(VeloxQuantCLI.methodsArguments(family: .unknown), ["methods", "--json"])
    }

    func testPrecomputeAndBenchmarkUseSnakeCase() {
        XCTAssertEqual(VeloxQuantCLI.precomputeArguments(for: PrecomputeCLIRequest()), [
            "precompute", "--head_dim", "128", "--bits", "1", "2", "3", "4",
            "--jl_dim", "128", "--seed", "42", "--output_dir", "./artifacts/"
        ])
        XCTAssertEqual(
            VeloxQuantCLI.kvCacheMicrobenchmarkArguments(
                for: KVCacheMicrobenchmarkRequest(sequenceLengths: [512, 1024], compareOptimized: true)
            ),
            [
                "benchmark", "--method", "turboquant_prod", "--head_dim", "128", "--bits", "3", "--jl_dim", "128",
                "--seq_lens", "512", "1024", "--seed", "42", "--compare_optimized"
            ]
        )
    }

    func testProfileArgumentsFilterServerOwnedOverrides() {
        let arguments = VeloxQuantCLI.profileArguments(for: ProfileCLIRequest(
            model: "m", method: "kivi", bits: 3, maxTokens: 16,
            setOverrides: ["kivi_group_size": "64", "bit_width_inlier": "4", "seed": "1", "empty": ""]
        ))
        XCTAssertEqual(arguments, [
            "profile", "--model", "m", "--method", "kivi", "--bits", "3", "--max-tokens", "16",
            "--set", "kivi_group_size=64"
        ])
    }

    func testRecommendInputMappings() {
        XCTAssertEqual(VeloxQuantCLI.recommendChipArgument(for: .m5), "M4")
        XCTAssertEqual(VeloxQuantCLI.recommendChipArgument(for: .m2), "M2")

        XCTAssertEqual(VeloxQuantCLI.ramBucket(forBytes: 18 * 1_073_741_824), 16)
        XCTAssertEqual(VeloxQuantCLI.ramBucket(forBytes: 8 * 1_073_741_824), 8)
        XCTAssertEqual(VeloxQuantCLI.ramBucket(forBytes: 36 * 1_073_741_824), 36)
        XCTAssertNil(VeloxQuantCLI.ramBucket(forBytes: 4 * 1_073_741_824))

        XCTAssertEqual(VeloxQuantCLI.modelClass(forParameterCount: 7_000_000_000), "7B")
        XCTAssertEqual(VeloxQuantCLI.modelClass(forParameterCount: 8_000_000_000), "14B")
        XCTAssertEqual(VeloxQuantCLI.modelClass(forParameterCount: 1_000_000_000), "1B")
        XCTAssertNil(VeloxQuantCLI.modelClass(forParameterCount: 1_000_000_000_000))
    }

    // MARK: - Shell-out + decoding

    func testRecommendRunsUnderPythonModuleAndDecodes() async throws {
        let runner = FakeProcessRunner { _ in .success(Fixtures.recommendJSON()) }
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: runner)
        let response = try await cli.recommend(RecommendCLIRequest(chip: "M3", ramGB: 16, modelClass: "14B"))

        XCTAssertEqual(response.recommendation.method, "turboquant_rvq")
        XCTAssertEqual(response.recommendation.knobs["bit_width_inlier"], .int(1))
        XCTAssertEqual(response.recommendation.kvFP16MB, 1152.0)
        XCTAssertEqual(runner.calls.first?.executable, "/venv/bin/python3")
        XCTAssertEqual(Array(runner.calls.first?.arguments.prefix(3) ?? []), ["-m", "veloxquant_mlx", "recommend"])
    }

    func testMethodsDecodesLenientlyIncludingUnknownFamilyAndCrashesTier() async throws {
        let runner = FakeProcessRunner { _ in .success(Fixtures.methodsJSON) }
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: runner)
        let response = try await cli.methods()

        XCTAssertEqual(response.defaultServeMethod, "turboquant_rvq")
        XCTAssertTrue(response.accountingOnly)
        XCTAssertEqual(response.methods.map(\.name), ["turboquant_rvq", "kivi", "future"])

        let rvq = response.methods[0]
        XCTAssertEqual(rvq.family, .quantization)
        XCTAssertEqual(rvq.serveTier, .accountingOnly)
        XCTAssertEqual(rvq.telemetryCoverage, .keysOnly)
        XCTAssertEqual(rvq.fieldSchema[1].defaultValue, .array([.int(8), .int(4), .int(2)]))
        XCTAssertEqual(rvq.docsURL?.absoluteString, "https://example.com/rvq")
        XCTAssertEqual(response.methods[1].telemetryCoverage, .full)

        // Regression tests modeled on Studio's two historical decode bugs.
        let future = response.methods[2]
        XCTAssertEqual(future.family, .unknown, "an unrecognized family must not fail the whole list (Studio #42)")
        XCTAssertEqual(future.serveTier, .crashes, "wire value is \"crashes\", not \"unsupported\"")
        XCTAssertFalse(future.serveTier.isServable)
        XCTAssertEqual(future.telemetryCoverage, .none, "unknown coverage degrades to the conservative reading")
    }

    func testMethodsAccountingOnlyDefaultsToTrueWhenAbsent() throws {
        let json = #"{"schema_version":1,"default_serve_method":"x","methods":[]}"#
        let response = try JSONDecoder().decode(MethodsResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.accountingOnly)
    }

    func testAutoConfigDecodesKnobsDynamically() async throws {
        let runner = FakeProcessRunner { _ in .success(Fixtures.autoConfigJSON) }
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: runner)
        let response = try await cli.autoConfig(AutoConfigCLIRequest())
        XCTAssertEqual(response.config.method, "kivi")
        XCTAssertEqual(response.config.headDimension, 128)
        XCTAssertEqual(response.config.knobs, ["bit_width_inlier": .int(2), "kivi_group_size": .int(32)])
        XCTAssertEqual(response.reason, "memory pressure moderate; kivi 2-bit")
    }

    func testNonZeroExitThrowsCLICommandFailed() async {
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: FakeProcessRunner { _ in
            .failure(2, stderr: "legacy mode requires --chip")
        })
        do {
            _ = try await cli.recommend(RecommendCLIRequest(chip: "M3", ramGB: 16, modelClass: "7B"))
            XCTFail("expected failure")
        } catch VeloxQuantError.cliCommandFailed(let command, let exitCode, let stderr) {
            XCTAssertTrue(command.hasPrefix("/venv/bin/python3 -m veloxquant_mlx recommend"))
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(stderr, "legacy mode requires --chip")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUndecodableOutputThrowsMalformedCLIOutput() async {
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: FakeProcessRunner { _ in .success("[]") })
        do {
            _ = try await cli.methods()
            XCTFail("expected failure")
        } catch VeloxQuantError.malformedCLIOutput(_, let raw, _) {
            XCTAssertEqual(raw, "[]")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLaunchFailureMapsToPythonEnvironmentNotFound() async {
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: FakeProcessRunner { call in
            throw ProcessLaunchError(executable: call.executable, reason: "gone")
        })
        do {
            try await cli.precompute(PrecomputeCLIRequest())
            XCTFail("expected failure")
        } catch VeloxQuantError.pythonEnvironmentNotFound {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMicrobenchmarkTableParsing() async throws {
        let stdout = """

        === veloxquant_mlx benchmark ===
        Method: turboquant_prod, head_dim=128, bits=3, jl_dim=128
        seq_len | baseline_attend_ms | optimized_attend_ms | speedup
            512 |              1.250 |               0.500 |   2.500x
           1024 |              2.000
        """
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: FakeProcessRunner { _ in .success(stdout) })
        let result = try await cli.runKvCacheMicrobenchmark(KVCacheMicrobenchmarkRequest())
        XCTAssertEqual(result.rows.count, 2)
        typealias Row = KVCacheMicrobenchmarkResult.Row
        XCTAssertEqual(
            result.rows[0],
            Row(sequenceLength: 512, baselineAttendMs: 1.25, optimizedAttendMs: 0.5, speedup: 2.5)
        )
        XCTAssertEqual(
            result.rows[1],
            Row(sequenceLength: 1024, baselineAttendMs: 2, optimizedAttendMs: nil, speedup: nil)
        )
        XCTAssertEqual(result.rawLines.count, 5)
    }

    func testProfilePassesThroughRawJSON() async throws {
        let cli = VeloxQuantCLI(pythonEnvironment: Fixtures.python, runner: FakeProcessRunner { _ in
            .success(#"{"layers":[{"idx":0,"ms":1.5}],"accounting_only":true}"#)
        })
        let profile = try await cli.profile(ProfileCLIRequest(model: "m"))
        XCTAssertEqual(profile["accounting_only"], .bool(true))
        XCTAssertEqual(profile["layers"], .array([.object(["idx": .int(0), "ms": .double(1.5)])]))
    }

    // MARK: - Registry functions

    func testListMethodsLivesInRuntimeAndUsesMethodsJSON() async throws {
        let runner = FakeProcessRunner { _ in .success(Fixtures.methodsJSON) }
        let methods = try await VeloxQuantProcess.listMethods(
            pythonEnvironment: Fixtures.python, servableOnly: true, runner: runner
        )
        XCTAssertEqual(methods.count, 3)
        XCTAssertEqual(runner.calls.first?.arguments, ["-m", "veloxquant_mlx", "methods", "--json", "--servable-only"])
    }

    func testListLocalModelsScansHFCacheWithoutDoubleCountingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("models--mlx-community--Qwen3-8B-4bit", isDirectory: true)
        let blobs = model.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = model.appendingPathComponent("snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: blobs.appendingPathComponent("sha1"))
        try Data(count: 24).write(to: blobs.appendingPathComponent("sha2"))
        try FileManager.default.createSymbolicLink(
            at: snapshot.appendingPathComponent("model.safetensors"),
            withDestinationURL: blobs.appendingPathComponent("sha1")
        )
        for other in ["datasets--x--y", "models--a--b"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(other), withIntermediateDirectories: true
            )
        }

        let models = VeloxQuantProcess.listLocalModels(cacheDirectory: root)
        XCTAssertEqual(models.map(\.repoID), ["a/b", "mlx-community/Qwen3-8B-4bit"])
        XCTAssertEqual(models[1].sizeBytes, 1024)
        XCTAssertNotNil(models[1].lastModified)
        XCTAssertEqual(models[0].sizeBytes, 0)
    }

    func testListLocalModelsReturnsEmptyForMissingCache() {
        XCTAssertEqual(VeloxQuantProcess.listLocalModels(cacheDirectory: URL(fileURLWithPath: "/no/such/dir")), [])
    }

    func testDefaultCacheDirectoryHonorsHFHome() {
        XCTAssertEqual(VeloxQuantProcess.defaultModelCacheDirectory(environment: ["HF_HOME": "/hf"]).path, "/hf/hub")
        let defaultPath = VeloxQuantProcess.defaultModelCacheDirectory(environment: [:]).path
        XCTAssertTrue(defaultPath.hasSuffix(".cache/huggingface/hub"))
    }
}
