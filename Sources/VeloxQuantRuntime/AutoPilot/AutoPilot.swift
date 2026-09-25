#if os(macOS)

import Foundation
import VeloxQuantCore

/// Which model AutoPilot should plan for. Go's `AutoPilotConfig.Model` (`""`/`"auto"` or a
/// registry name), plus a caller-supplied `ModelInfo` for models outside the curated registry.
public enum ModelSelection: Sendable, Equatable {
    /// Rank the registry for `task` (all tasks if `nil`) against available memory — Go's
    /// `Model: "auto"` path via `RecommendScored`.
    case auto(task: ModelTask?)
    /// A registry model by exact name; unknown names throw `VeloxQuantError.modelNotFound`
    /// (Go's `ErrModelNotFound`).
    case named(String)
    /// A model you describe yourself.
    case custom(ModelInfo)
}

/// An AutoPilot request (Go's `AutoPilotConfig` + the TS/Kotlin `goal`/`force` fields).
public struct AutoPilotRequest: Sendable, Equatable {
    /// Model to plan for.
    public var model: ModelSelection
    /// Context length; `nil` uses 8192 (Go's `defaultContextLength`).
    public var contextLength: Int?
    /// `recommend --goal`.
    public var goal: RecommendGoal
    /// Overrides the `--model-class` derived from the model's parameter count.
    public var modelClass: String?
    /// Proceed even when `recommend` warns the workload will not fit (TS/Kotlin `force`).
    public var force: Bool

    /// Creates a request.
    public init(
        model: ModelSelection = .auto(task: nil),
        contextLength: Int? = nil,
        goal: RecommendGoal = .everyday,
        modelClass: String? = nil,
        force: Bool = false
    ) {
        self.model = model
        self.contextLength = contextLength
        self.goal = goal
        self.modelClass = modelClass
        self.force = force
    }
}

/// "This workload likely won't fit." Carries exactly the payload of
/// `VeloxQuantError.autopilotWontFit` (`asVeloxQuantError`), so the sealed and throwing entry
/// points can never drift apart.
public struct AutopilotFitError: Error, LocalizedError, Sendable, Equatable {
    /// The `recommend` warnings that matched `AutoPilot.wontFitPattern`.
    public let warnings: [String]
    /// The full `recommend` result.
    public let recommendation: Recommendation
    /// Human-readable summary (TS's `AutopilotFitError` message shape).
    public let message: String

    /// Creates the error; `message` is derived from `warnings`.
    public init(warnings: [String], recommendation: Recommendation) {
        self.warnings = warnings
        self.recommendation = recommendation
        self.message = "veloxquant recommend reports this configuration likely will not fit:\n"
            + warnings.map { "  - \($0)" }.joined(separator: "\n")
            + "\n\nPass `force: true` to start anyway."
    }

    /// Human-readable description.
    public var errorDescription: String? { message }

    /// The identical payload as a `VeloxQuantError`.
    public var asVeloxQuantError: VeloxQuantError {
        .autopilotWontFit(warnings: warnings, recommendation: recommendation)
    }
}

/// `AutoPilot.tryStart`'s result: branch on "won't fit" as data (exhaustively checked).
public enum AutoPilotOutcome: Sendable {
    /// Ready to use.
    case started(AutoPilotSession)
    /// `recommend` warned the workload won't fit and `force` was false.
    case wontFit(AutopilotFitError)
}

/// Every decision AutoPilot made, so the process is transparent and debuggable — Go's
/// `AutoPilotPlan`/`Session.Plan()`, extended with the CLI inputs/outputs this SDK's shell-out
/// design adds.
public struct AutoPilotPlan: Sendable, Equatable {
    /// The Mac, as detected.
    public let hardware: HardwareInfo
    /// Host memory at planning time (`availableBytes` drives model ranking, as in Go).
    public let hostMemory: HostMemory
    /// The chosen model.
    public let selectedModel: ModelInfo
    /// Why it was chosen (ranking reason, or that it was pinned).
    public let selectionReason: String
    /// Context length planned for.
    public let contextLength: Int
    /// Offline estimate for the chosen model at `contextLength` (fp16 KV vs int4 accounting).
    public let memoryEstimate: MemoryEstimate
    /// 15% of available memory reserved as headroom (Go's `safetyMarginRatio`).
    public let safetyMarginBytes: UInt64
    /// The exact `recommend` inputs used.
    public let recommendRequest: RecommendCLIRequest
    /// `recommend`'s answer.
    public let recommendation: Recommendation
    /// `recommend` warnings matching `AutoPilot.wontFitPattern` (non-empty only when forced).
    public let wontFitWarnings: [String]
    /// The compression method to serve with.
    public let method: String
    /// The bit width to serve with, if the chosen knobs name one.
    public let bits: Int?
    /// Whether `recommend`'s method wasn't servable and `auto-config`'s pool was used instead.
    public let usedServeSafeFallback: Bool
    /// `auto-config`'s reason, when the fallback was used.
    public let fallbackReason: String?
    /// Ordered, human-readable trail of every decision above.
    public let decisions: [String]
    /// Always `true`: compression byte counts are accounting-only (see `MemoryEstimate`).
    public let accountingOnly: Bool

    /// A `ServeConfig` launching the chosen model/method/bits (`bits` defaults to serve's 2).
    public var serveConfig: ServeConfig {
        ServeConfig(model: selectedModel.name, method: method, bits: bits ?? 2, port: 8000)
    }
}

/// A ready-to-use session bound to AutoPilot's chosen model (Go's `Session`, Kotlin's/TS's
/// `AutoPilotSession`).
public struct AutoPilotSession: Sendable {
    /// Every decision behind this session — Go's `Session.Plan()`.
    public let plan: AutoPilotPlan
    /// The client requests go through.
    public let client: VeloxQuantClient

    /// Sends a single user message with the planned model (Go's `Session.Chat`).
    public func chat(_ prompt: String) async throws -> ChatResponse {
        try await client.chat(ChatRequest(messages: [.user(prompt)], model: plan.selectedModel.name))
    }

    /// Sends `request`, filling in the planned model if `request.model` is `nil`.
    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        try await client.chat(withPlannedModel(request))
    }

    /// Streams `request`, filling in the planned model if `request.model` is `nil`.
    public func chatStream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        client.chatStream(withPlannedModel(request))
    }

    /// A history-tracking `Conversation` bound to the planned model (Go's `Session.Conversation`).
    public func conversation(system: String? = nil) -> Conversation {
        Conversation(client: client, model: plan.selectedModel.name, system: system)
    }

    private func withPlannedModel(_ request: ChatRequest) -> ChatRequest {
        var request = request
        if request.model == nil {
            request.model = plan.selectedModel.name
        }
        return request
    }
}

/// Injectable inputs for `AutoPilot`, so tests run without real hardware or Python.
public struct AutoPilotDependencies: Sendable {
    /// Hardware detection.
    public var hardware: @Sendable () -> HardwareInfo
    /// Host memory snapshot.
    public var hostMemory: @Sendable () -> HostMemory
    /// Subprocess runner for the CLI shell-outs.
    public var runner: ProcessRunning
    /// Model registry for `.auto`/`.named` selection.
    public var registry: ModelRegistry

    /// Creates dependencies; defaults are the live implementations.
    public init(
        hardware: @escaping @Sendable () -> HardwareInfo = { HardwareDetector.detect() },
        hostMemory: @escaping @Sendable () -> HostMemory = { HostMemory.current() },
        runner: ProcessRunning = FoundationProcessRunner(),
        registry: ModelRegistry = ModelRegistry()
    ) {
        self.hardware = hardware
        self.hostMemory = hostMemory
        self.runner = runner
        self.registry = registry
    }
}

/// AutoPilot: inspect the Mac, pick a compatible model, and choose a compression strategy with
/// a fully transparent decision trail (`AutoPilotSession.plan`).
///
/// This is a deliberate synthesis of the two sibling architectures (see CHANGELOG "Changed"):
///
/// - **Hardware inspection, model selection, context length, safety margin, and `plan`** follow
///   Go's `Client.AutoPilot` (`veloxquant-go/autopilot.go`): the curated registry ranked by
///   `ModelRegistry.recommendScored` against available memory, a pinned model looked up by
///   name, 8192-token default context, 15% safety margin.
/// - **The compression strategy is never computed locally**: it comes from the real Python
///   `recommend --json` CLI, with the `wontFitPattern` check and the fallback to
///   `auto-config`'s serve-safe pool when `recommend`'s method isn't servable — the TS SDK's
///   `autopilot()` (`veloxquant-sdk/src/autopilot.ts`), which Kotlin and VeloxQuant-Studio also
///   follow. This honors plan non-goal 11: no local reimplementation of the Python ruleset.
///
/// macOS-only, full stop — unavailable on iOS/iPadOS/watchOS/tvOS/visionOS and on a Mac with no
/// discoverable Python environment. The intended non-macOS substitute is `VeloxQuantCore`'s
/// `OfflineOptimizer` (pure computation, `isOfflineEstimate == true`), or a companion process on
/// the Mac. AutoPilot does not launch `serve` itself (Go and Kotlin don't either); pass
/// `plan.serveConfig` to `VeloxQuantProcess.start` to do so.
public actor AutoPilot {
    /// Matches `recommend` warnings that mean "will not fit" — TS's `WONT_FIT_PATTERN`
    /// (`/will not fit|short of any headroom/i`). The CLI has no structured severity field, so
    /// this depends on `mac_recommender.py`'s wording staying stable; inspect
    /// `recommendation.warnings` directly if in doubt.
    public static let wontFitPhrases = ["will not fit", "short of any headroom"]

    /// Methods whose knobs carry the bit width, in TS's `extractBitWidth` order.
    static let bitWidthKnobs = ["bit_width_inlier", "kvquant_bits", "gear_bits", "kivi_bits"]

    /// Go's `defaultContextLength`.
    public static let defaultContextLength = 8192
    /// Go's `safetyMarginRatio`.
    public static let safetyMarginRatio = 0.15

    /// Whether `warning` matches the won't-fit heuristic (case-insensitive).
    public static func wontFitPattern(matches warning: String) -> Bool {
        let lowered = warning.lowercased()
        return wontFitPhrases.contains { lowered.contains($0) }
    }

    /// Plans a session, returning `.wontFit` (instead of throwing) when `recommend` warns the
    /// workload won't fit and `request.force` is false.
    ///
    /// - Throws: `VeloxQuantError.modelNotFound`/`.noModelFits` (selection),
    ///   `.unsupportedPlatform` (no recognizable Apple Silicon chip or < 8 GB RAM for
    ///   `recommend`), `.cliCommandFailed`/`.malformedCLIOutput`/`.pythonEnvironmentNotFound`
    ///   (shell-outs), or `MemoryEstimatorError` for a non-positive context length.
    public static func tryStart(
        _ request: AutoPilotRequest,
        pythonEnvironment: PythonEnvironment,
        client: VeloxQuantClient = VeloxQuantClient(),
        dependencies: AutoPilotDependencies = AutoPilotDependencies()
    ) async throws -> AutoPilotOutcome {
        var decisions: [String] = []
        let local = try planLocally(request, dependencies: dependencies, decisions: &decisions)
        let cli = VeloxQuantCLI(pythonEnvironment: pythonEnvironment, runner: dependencies.runner)

        let recommendRequest = try makeRecommendRequest(
            request, model: local.model, hardware: local.hardware, contextLength: local.contextLength
        )
        let recommendation = try await cli.recommend(recommendRequest).recommendation
        decisions.append(
            "recommend (--chip \(recommendRequest.chip) --ram-gb \(recommendRequest.ramGB) "
                + "--model-class \(recommendRequest.modelClass) --goal \(recommendRequest.goal.rawValue)): "
                + "\(recommendation.method) — \(recommendation.rationale)"
        )

        let wontFit = recommendation.warnings.filter(wontFitPattern(matches:))
        if !wontFit.isEmpty {
            guard request.force else {
                return .wontFit(AutopilotFitError(warnings: wontFit, recommendation: recommendation))
            }
            decisions.append("won't-fit warnings overridden by force: \(wontFit.joined(separator: " | "))")
        }

        let serve = try await resolveServeMethod(recommendation, local: local, cli: cli, decisions: &decisions)
        let plan = AutoPilotPlan(
            hardware: local.hardware,
            hostMemory: local.memory,
            selectedModel: local.model,
            selectionReason: local.selectionReason,
            contextLength: local.contextLength,
            memoryEstimate: local.estimate,
            safetyMarginBytes: local.safetyMargin,
            recommendRequest: recommendRequest,
            recommendation: recommendation,
            wontFitWarnings: wontFit,
            method: serve.method,
            bits: serve.bits,
            usedServeSafeFallback: serve.fallbackReason != nil,
            fallbackReason: serve.fallbackReason,
            decisions: decisions,
            accountingOnly: true
        )
        return .started(AutoPilotSession(plan: plan, client: client))
    }

    /// Like `tryStart`, but throws `VeloxQuantError.autopilotWontFit` (the same payload as
    /// `AutoPilotOutcome.wontFit`) instead of returning it.
    public static func start(
        _ request: AutoPilotRequest,
        pythonEnvironment: PythonEnvironment,
        client: VeloxQuantClient = VeloxQuantClient(),
        dependencies: AutoPilotDependencies = AutoPilotDependencies()
    ) async throws -> AutoPilotSession {
        let outcome = try await tryStart(
            request, pythonEnvironment: pythonEnvironment, client: client, dependencies: dependencies
        )
        switch outcome {
        case .started(let session): return session
        case .wontFit(let fitError): throw fitError.asVeloxQuantError
        }
    }

    // MARK: - Steps

    /// Everything decided before any shell-out (Go's `Client.AutoPilot` up to `Optimize.Recommend`).
    struct LocalPlan {
        let hardware: HardwareInfo
        let memory: HostMemory
        let contextLength: Int
        let model: ModelInfo
        let selectionReason: String
        let estimate: MemoryEstimate
        let safetyMargin: UInt64
    }

    static func planLocally(
        _ request: AutoPilotRequest,
        dependencies: AutoPilotDependencies,
        decisions: inout [String]
    ) throws -> LocalPlan {
        let hardware = dependencies.hardware()
        let memory = dependencies.hostMemory()
        decisions.append(
            "hardware: \(hardware.chipName), \(format(memory.totalBytes)) total, "
                + "\(format(memory.availableBytes)) available"
        )

        let requested = request.contextLength ?? 0
        let contextLength = requested > 0 ? requested : defaultContextLength
        decisions.append("context length: \(contextLength) tokens" + (requested > 0 ? " (requested)" : " (default)"))

        let (model, selectionReason) = try selectModel(
            request, availableBytes: memory.availableBytes, dependencies: dependencies
        )
        decisions.append("model: \(model.name) — \(selectionReason)")

        let estimate = try MemoryEstimator.estimate(MemoryRequest(
            architecture: model.architecture,
            contextLength: contextLength
        ))
        let safetyMargin = UInt64(Double(memory.availableBytes) * safetyMarginRatio)
        decisions.append(
            "offline estimate: \(format(estimate.totalMemoryBytes)) unoptimized, "
                + "\(format(estimate.optimizedTotalBytes)) with \(estimate.recommendedStrategy) "
                + "(accounting-only); safety margin \(format(safetyMargin))"
        )
        return LocalPlan(
            hardware: hardware, memory: memory, contextLength: contextLength, model: model,
            selectionReason: selectionReason, estimate: estimate, safetyMargin: safetyMargin
        )
    }

    /// The method/bits to serve with, and `auto-config`'s reason when it had to pick them.
    struct ServeChoice {
        let method: String
        let bits: Int?
        let fallbackReason: String?
    }

    /// TS's servability check: keep `recommend`'s method if `methods --servable-only` lists it,
    /// otherwise take `auto-config`'s pick from the serve-safe pool.
    static func resolveServeMethod(
        _ recommendation: Recommendation,
        local: LocalPlan,
        cli: VeloxQuantCLI,
        decisions: inout [String]
    ) async throws -> ServeChoice {
        let servable = Set(try await cli.methods(servableOnly: true).methods.map(\.name))
        let recommendedBits = extractBitWidth(recommendation.knobs)
        if servable.contains(recommendation.method) {
            decisions.append(
                "serve: \(recommendation.method) is servable" + (recommendedBits.map { ", \($0)-bit" } ?? "")
            )
            return ServeChoice(method: recommendation.method, bits: recommendedBits, fallbackReason: nil)
        }
        let autoConfig = try await cli.autoConfig(AutoConfigCLIRequest(
            headDimension: local.model.architecture.headDimension,
            sequenceLength: local.contextLength,
            layerCount: local.model.architecture.layerCount,
            totalMemoryBytes: local.hardware.unifiedMemoryBytes
        ))
        let bits = extractBitWidth(autoConfig.config.knobs)
        decisions.append(
            "serve: \(recommendation.method) is not servable; auto-config picked \(autoConfig.config.method)"
                + (bits.map { ", \($0)-bit" } ?? "") + " — \(autoConfig.reason)"
        )
        return ServeChoice(method: autoConfig.config.method, bits: bits, fallbackReason: autoConfig.reason)
    }

    /// Go's `selectModel`: a pinned model is looked up (or taken as given); otherwise the best
    /// `recommendScored` candidate wins.
    static func selectModel(
        _ request: AutoPilotRequest,
        availableBytes: UInt64,
        dependencies: AutoPilotDependencies
    ) throws -> (ModelInfo, String) {
        switch request.model {
        case .custom(let info):
            return (info, "caller-supplied model")
        case .named(let name):
            guard let info = dependencies.registry.model(named: name) else {
                throw VeloxQuantError.modelNotFound(name: name)
            }
            return (info, "explicitly requested")
        case .auto(let task):
            let candidates = try dependencies.registry.recommendScored(
                task: task,
                availableMemoryBytes: availableBytes,
                contextLength: request.contextLength
            )
            guard let best = candidates.first else {
                if dependencies.registry.models.isEmpty {
                    throw VeloxQuantError.modelNotFound(name: "(registry is empty)")
                }
                throw VeloxQuantError.noModelFits(task: task?.rawValue, availableMemoryBytes: availableBytes)
            }
            return (best.info, best.reason)
        }
    }

    static func makeRecommendRequest(
        _ request: AutoPilotRequest,
        model: ModelInfo,
        hardware: HardwareInfo,
        contextLength: Int
    ) throws -> RecommendCLIRequest {
        guard let chip = hardware.chipFamily else {
            throw VeloxQuantError.unsupportedPlatform(
                feature: "AutoPilot (veloxquant recommend --chip)",
                platform: hardware.chipName
            )
        }
        guard let ramGB = VeloxQuantCLI.ramBucket(forBytes: hardware.unifiedMemoryBytes) else {
            throw VeloxQuantError.unsupportedPlatform(
                feature: "AutoPilot (veloxquant recommend --ram-gb needs at least 8 GB)",
                platform: "\(hardware.chipName), \(hardware.unifiedMemoryBytes) bytes"
            )
        }
        let parameters = model.parameters > 0 ? model.parameters : model.architecture.parameterCount
        guard let modelClass = request.modelClass ?? VeloxQuantCLI.modelClass(forParameterCount: parameters) else {
            throw VeloxQuantError.modelNotFound(
                name: "\(model.name) (no recommend --model-class covers \(parameters) parameters)"
            )
        }
        return RecommendCLIRequest(
            chip: VeloxQuantCLI.recommendChipArgument(for: chip),
            ramGB: ramGB,
            modelClass: modelClass,
            goal: request.goal,
            sequenceLength: contextLength,
            layerCount: model.architecture.layerCount,
            kvHeadCount: model.architecture.kvHeadCount,
            headDimension: model.architecture.headDimension
        )
    }

    /// TS's `extractBitWidth`: the first integer among `bitWidthKnobs`.
    static func extractBitWidth(_ knobs: [String: JSONValue]) -> Int? {
        for key in bitWidthKnobs {
            if case .int(let value)? = knobs[key] {
                return value
            }
        }
        return nil
    }

    private static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
