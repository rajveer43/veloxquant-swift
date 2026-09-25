#if os(macOS)

import Foundation
import VeloxQuantCore

/// One-shot `python -m veloxquant_mlx <subcommand>` shell-outs: `recommend`, `auto-config`,
/// `methods`, `profile`, `precompute`, and the `benchmark` KV-cache micro-benchmark — the same
/// subcommand set Kotlin's `CliShellOut` wraps.
///
/// Every argument list comes from a pure `static func ...Arguments(for:)` builder (Studio's
/// "split out so it's unit-testable without launching a real process" convention). Flag
/// spelling is per-subcommand, exactly as the Python CLI defines it: kebab-case for
/// `recommend`/`auto-config`/`serve`/`profile`, snake_case for `precompute`/`benchmark`.
/// Several of Kotlin's builders do not match the real CLI (see CHANGELOG); these were checked
/// flag-by-flag against `veloxquant_mlx/cli/*.py`.
public struct VeloxQuantCLI: Sendable {
    /// The interpreter every subcommand runs under.
    public let pythonEnvironment: PythonEnvironment
    private let runner: ProcessRunning

    /// Creates a CLI wrapper. `runner` is injectable for tests.
    public init(pythonEnvironment: PythonEnvironment, runner: ProcessRunning = FoundationProcessRunner()) {
        self.pythonEnvironment = pythonEnvironment
        self.runner = runner
    }

    // MARK: - Subcommands

    /// Runs `recommend --json` (legacy chip/RAM/model-class/goal mode).
    public func recommend(_ request: RecommendCLIRequest) async throws -> RecommendResponse {
        try await runJSON(Self.recommendArguments(for: request), as: RecommendResponse.self)
    }

    /// Runs `auto-config --json` — selection from the serve-safe method pool.
    public func autoConfig(_ request: AutoConfigCLIRequest) async throws -> AutoConfigResponse {
        try await runJSON(Self.autoConfigArguments(for: request), as: AutoConfigResponse.self)
    }

    /// Runs `methods --json`, optionally filtered to servable methods and/or one family.
    public func methods(servableOnly: Bool = false, family: MethodFamily? = nil) async throws -> MethodsResponse {
        try await runJSON(Self.methodsArguments(servableOnly: servableOnly, family: family), as: MethodsResponse.self)
    }

    /// Runs `profile` (always JSON) and returns the raw object — its field set is not pinned by
    /// any sibling SDK or plan, so this is a passthrough rather than a guessed typed struct.
    public func profile(_ request: ProfileCLIRequest) async throws -> [String: JSONValue] {
        try await runJSON(Self.profileArguments(for: request), as: [String: JSONValue].self)
    }

    /// Runs `precompute` (writes files, no JSON). Returns normally on exit code 0.
    public func precompute(_ request: PrecomputeCLIRequest) async throws {
        _ = try await runChecked(Self.precomputeArguments(for: request))
    }

    /// Runs `benchmark` and parses its plain-text table.
    public func runKvCacheMicrobenchmark(
        _ request: KVCacheMicrobenchmarkRequest
    ) async throws -> KVCacheMicrobenchmarkResult {
        let output = try await runChecked(Self.kvCacheMicrobenchmarkArguments(for: request))
        return Self.parseMicrobenchmarkTable(output.stdout)
    }

    // MARK: - Pure argument builders

    /// `--set` keys the CLI already sets from a dedicated flag (`--bits` → `bit_width_inlier`,
    /// `--seed` → `seed`); passing them via `--set` too crashes the server with a duplicate
    /// keyword argument. Studio's `serverOwnedOverrideKeys`, verbatim.
    public static let serverOwnedOverrideKeys: Set<String> = ["bit_width_inlier", "seed"]

    /// `recommend`'s `--ram-gb` choices (`ALLOWED_RAM_GB`, `tools/mac_recommender.py`).
    public static let allowedRAMGB = [8, 16, 24, 32, 36, 48, 64, 96, 128, 192, 512]

    /// `recommend`'s `--model-class` choices, with their parameter counts in billions
    /// (`MODEL_WEIGHT_GB_4BIT`'s keys, `tools/mac_recommender.py`).
    public static let modelClasses: [(name: String, billions: Double)] = [
        ("1B", 1), ("3B", 3), ("7B", 7), ("14B", 14), ("32B", 32),
        ("70B", 70), ("120B", 120), ("235B", 235), ("671B", 671)
    ]

    /// `recommend --chip` accepts only `M1`–`M4`; an M5 maps to `M4`. This is Studio's
    /// `MacChipFamily.recommenderArgument`, moved to the CLI-argument layer per the plan so
    /// `AppleSiliconChip` stays "what is true about this Mac".
    public static func recommendChipArgument(for chip: AppleSiliconChip) -> String {
        switch chip {
        case .m5: return AppleSiliconChip.m4.rawValue
        case .m1, .m2, .m3, .m4: return chip.rawValue
        }
    }

    /// The largest allowed `--ram-gb` bucket not exceeding `bytes` (GiB), or `nil` if below 8.
    /// Rounds **down** so a Mac with 18 GB is described as 16 GB — the conservative direction for
    /// a fit check.
    public static func ramBucket(forBytes bytes: UInt64) -> Int? {
        let gib = Double(bytes) / 1_073_741_824
        return allowedRAMGB.last { Double($0) <= gib + 0.01 }
    }

    /// The smallest `--model-class` at least as large as `parameterCount`, or `nil` above 671B.
    /// Rounds **up** (an 8B model is described as `14B`) — conservative for a fit check.
    public static func modelClass(forParameterCount parameterCount: UInt64) -> String? {
        let billions = Double(parameterCount) / 1_000_000_000
        return modelClasses.first { $0.billions >= billions - 0.05 }?.name
    }

    /// `-m veloxquant_mlx recommend ... --json` (kebab-case flags).
    public static func recommendArguments(for request: RecommendCLIRequest) -> [String] {
        [
            "recommend",
            "--chip", request.chip,
            "--ram-gb", String(request.ramGB),
            "--model-class", request.modelClass,
            "--goal", request.goal.rawValue,
            "--seq-len", String(request.sequenceLength),
            "--n-layers", String(request.layerCount),
            "--n-kv-heads", String(request.kvHeadCount),
            "--head-dim", String(request.headDimension),
            "--json"
        ]
    }

    /// `auto-config ... --json` (kebab-case flags).
    public static func autoConfigArguments(for request: AutoConfigCLIRequest) -> [String] {
        var arguments = [
            "auto-config",
            "--head-dim", String(request.headDimension),
            "--seq-len", String(request.sequenceLength),
            "--n-layers", String(request.layerCount),
            "--batch-size", String(request.batchSize)
        ]
        if let total = request.totalMemoryBytes {
            arguments += ["--total-memory-bytes", String(total)]
            if let active = request.activeMemoryBytes {
                arguments += ["--active-memory-bytes", String(active)]
            }
        }
        return arguments + ["--json"]
    }

    /// `methods --json [--servable-only] [--family F]`.
    public static func methodsArguments(servableOnly: Bool = false, family: MethodFamily? = nil) -> [String] {
        var arguments = ["methods", "--json"]
        if servableOnly {
            arguments.append("--servable-only")
        }
        if let family, family != .unknown {
            arguments += ["--family", family.rawValue]
        }
        return arguments
    }

    /// `profile --model M [--method] --bits B [--prompt] [--max-tokens] [--set k=v ...]`.
    public static func profileArguments(for request: ProfileCLIRequest) -> [String] {
        var arguments = ["profile", "--model", request.model]
        if let method = request.method {
            arguments += ["--method", method]
        }
        arguments += ["--bits", String(request.bits)]
        if let prompt = request.prompt {
            arguments += ["--prompt", prompt]
        }
        if let maxTokens = request.maxTokens {
            arguments += ["--max-tokens", String(maxTokens)]
        }
        return arguments + setArguments(request.setOverrides)
    }

    /// `precompute --head_dim ... --bits b1 b2 ... --jl_dim ... --seed ... --output_dir ...`.
    public static func precomputeArguments(for request: PrecomputeCLIRequest) -> [String] {
        ["precompute", "--head_dim", String(request.headDimension), "--bits"]
            + request.bits.map(String.init)
            + [
                "--jl_dim", String(request.jlDimension),
                "--seed", String(request.seed),
                "--output_dir", request.outputDirectory
            ]
    }

    /// `benchmark --method ... --head_dim ... --bits ... --jl_dim ... --seq_lens ... --seed ...
    /// [--compare_optimized]`.
    public static func kvCacheMicrobenchmarkArguments(for request: KVCacheMicrobenchmarkRequest) -> [String] {
        var arguments = [
            "benchmark",
            "--method", request.method,
            "--head_dim", String(request.headDimension),
            "--bits", String(request.bits),
            "--jl_dim", String(request.jlDimension),
            "--seq_lens"
        ] + request.sequenceLengths.map(String.init)
        arguments += ["--seed", String(request.seed)]
        if request.compareOptimized {
            arguments.append("--compare_optimized")
        }
        return arguments
    }

    /// `--set k=v` pairs, sorted by key for deterministic argument lists, with empty values and
    /// `serverOwnedOverrideKeys` dropped.
    static func setArguments(_ overrides: [String: String]) -> [String] {
        overrides
            .filter { !$0.value.isEmpty && !serverOwnedOverrideKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap { ["--set", "\($0.key)=\($0.value)"] }
    }

    /// Parses `benchmark`'s `seq_len | baseline_attend_ms [| optimized_attend_ms | speedup]`
    /// rows; header/banner lines are kept in `rawLines` only.
    static func parseMicrobenchmarkTable(_ stdout: String) -> KVCacheMicrobenchmarkResult {
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let rows = lines.compactMap { line -> KVCacheMicrobenchmarkResult.Row? in
            let columns = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 2,
                  let sequenceLength = Int(columns[0]),
                  let baseline = Double(columns[1])
            else { return nil }
            let optimized = columns.count >= 3 ? Double(columns[2]) : nil
            let speedup = columns.count >= 4 ? Double(columns[3].replacingOccurrences(of: "x", with: "")) : nil
            return KVCacheMicrobenchmarkResult.Row(
                sequenceLength: sequenceLength,
                baselineAttendMs: baseline,
                optimizedAttendMs: optimized,
                speedup: speedup
            )
        }
        return KVCacheMicrobenchmarkResult(rows: rows, rawLines: lines)
    }

    // MARK: - Execution

    private func commandDescription(_ subcommandArguments: [String]) -> String {
        let invocation = pythonEnvironment.invocation(subcommandArguments)
        return ([invocation.executable] + invocation.arguments).joined(separator: " ")
    }

    private func runChecked(_ subcommandArguments: [String]) async throws -> ProcessOutput {
        let invocation = pythonEnvironment.invocation(subcommandArguments)
        let output: ProcessOutput
        do {
            output = try await runner.run(executable: invocation.executable, arguments: invocation.arguments)
        } catch let error as ProcessLaunchError {
            throw VeloxQuantError.pythonEnvironmentNotFound(reason: error.localizedDescription)
        }
        guard output.exitCode == 0 else {
            throw VeloxQuantError.cliCommandFailed(
                command: commandDescription(subcommandArguments),
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        return output
    }

    private func runJSON<T: Decodable>(_ subcommandArguments: [String], as type: T.Type) async throws -> T {
        let output = try await runChecked(subcommandArguments)
        do {
            return try JSONDecoder().decode(T.self, from: Data(output.stdout.utf8))
        } catch {
            throw VeloxQuantError.malformedCLIOutput(
                command: commandDescription(subcommandArguments),
                raw: output.stdout,
                underlying: error
            )
        }
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
