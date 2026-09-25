import Foundation

/// A category of workload used for model recommendations. Port of Go's `models.Task`
/// (`veloxquant-go/models/model.go`); raw values match Go's strings.
public enum ModelTask: String, Codable, Sendable, CaseIterable {
    /// Code generation/editing.
    case coding
    /// Conversational chat.
    case chat
    /// Multi-step reasoning.
    case reasoning
    /// Image + text input.
    case vision
    /// Tool-using agents.
    case agent
    /// Translation.
    case translation
}

/// A model available for local inference. Port of Go's `models.Info`.
public struct ModelInfo: Sendable, Equatable, Hashable {
    /// Hugging Face repo id (e.g. `mlx-community/Qwen3-8B-4bit`).
    public var name: String
    /// Total parameter count.
    public var parameters: UInt64
    /// Architecture used for memory estimation.
    public var architecture: ModelArchitecture
    /// Tasks this model is suited to.
    public var tasks: [ModelTask]
    /// Whether this SDK considers the model supported.
    public var supported: Bool
    /// Whether this is a curated pick (receives a ranking bonus).
    public var recommended: Bool

    /// Creates a model description.
    public init(
        name: String,
        parameters: UInt64,
        architecture: ModelArchitecture,
        tasks: [ModelTask],
        supported: Bool = true,
        recommended: Bool = false
    ) {
        self.name = name
        self.parameters = parameters
        self.architecture = architecture
        self.tasks = tasks
        self.supported = supported
        self.recommended = recommended
    }
}

/// A candidate model paired with the score and reasoning behind its ranking. Port of Go's
/// `models.Scored`.
public struct ScoredModel: Sendable, Equatable {
    /// The candidate.
    public let info: ModelInfo
    /// Internal ranking value (higher is better); meaningful only relative to candidates from
    /// the same call.
    public let score: Double
    /// Human-readable explanation of the score.
    public let reason: String
}

/// Curated, offline registry of known-good local models, and task/memory-based ranking.
///
/// Port of Go's `models` package (`registry.go`, `recommend.go`): the four `staticRegistry`
/// entries (names, parameter counts, architectures, tasks, flags) are copied verbatim, and
/// `recommendScored(...)` reproduces Go's `RecommendScored` scoring exactly (task filter,
/// int4-at-context fit check, `headroom × 1.0 + 0.5` recommended bonus, stable sort).
/// Rust's `veloxquant-models` crate holds the same curated list.
public struct ModelRegistry: Sendable {
    /// The models this registry knows about.
    public let models: [ModelInfo]

    /// Creates a registry over `models` (defaults to the curated list shared with Go).
    public init(models: [ModelInfo] = ModelRegistry.curated) {
        self.models = models
    }

    /// Looks up a model by exact name.
    public func model(named name: String) -> ModelInfo? {
        models.first { $0.name == name }
    }

    /// Weight given to memory headroom when ranking (Go's `headroomWeight`).
    static let headroomWeight = 1.0
    /// Bonus for curated picks (Go's `recommendedBonus`).
    static let recommendedBonus = 0.5
    /// Context length assumed when none is given (Go's `RecommendScored` default).
    static let defaultContextLength = 8192

    /// Returns supported models suited to `task` (all tasks if `nil`), filtered to those whose
    /// int4 footprint at `contextLength` fits `availableMemoryBytes` (when non-zero), ranked
    /// best first with a reason for each.
    ///
    /// - Throws: `MemoryEstimatorError` only if an estimate fails (not reachable with a
    ///   positive context length).
    public func recommendScored(
        task: ModelTask?,
        availableMemoryBytes: UInt64,
        contextLength: Int? = nil
    ) throws -> [ScoredModel] {
        let context = (contextLength ?? 0) > 0 ? (contextLength ?? 0) : Self.defaultContextLength
        let taskLabel = task?.rawValue ?? ""
        var candidates: [ScoredModel] = []

        for model in models where model.supported {
            if let task, !model.tasks.contains(task) { continue }
            var score = model.recommended ? Self.recommendedBonus : 0

            guard availableMemoryBytes > 0 else {
                candidates.append(ScoredModel(
                    info: model,
                    score: score,
                    reason: "matches task \"\(taskLabel)\"; no memory budget given to rank by headroom"
                ))
                continue
            }

            let estimate = try MemoryEstimator.estimate(MemoryRequest(
                architecture: model.architecture,
                contextLength: context,
                precision: .int4,
                optimizedPrecision: .int4
            ))
            if estimate.totalMemoryBytes > availableMemoryBytes { continue }

            let headroom = 1 - Double(estimate.totalMemoryBytes) / Double(availableMemoryBytes)
            score += headroom * Self.headroomWeight
            let percent = String(format: "%.0f", headroom * 100)
            candidates.append(ScoredModel(
                info: model,
                score: score,
                reason: "fits task \"\(taskLabel)\" with \(percent)% memory headroom at \(context)-token context"
            ))
        }

        // Stable sort, best first — Go's `sort.SliceStable` on descending score.
        return candidates.enumerated()
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The curated model list, copied verbatim from Go's `models/registry.go` `staticRegistry`.
    public static let curated: [ModelInfo] = [
        ModelInfo(
            name: "mlx-community/Qwen3-8B-4bit",
            parameters: 8_000_000_000,
            architecture: ModelArchitecture(
                name: "mlx-community/Qwen3-8B-4bit", layerCount: 36, kvHeadCount: 8,
                headDimension: 128, hiddenSize: 4096, parameterCount: 8_000_000_000
            ),
            tasks: [.chat, .reasoning, .agent],
            recommended: true
        ),
        ModelInfo(
            name: "mlx-community/Qwen3-Coder-4bit",
            parameters: 8_000_000_000,
            architecture: ModelArchitecture(
                name: "mlx-community/Qwen3-Coder-4bit", layerCount: 36, kvHeadCount: 8,
                headDimension: 128, hiddenSize: 4096, parameterCount: 8_000_000_000
            ),
            tasks: [.coding, .agent],
            recommended: true
        ),
        ModelInfo(
            name: "mlx-community/gemma-2-9b-it-4bit",
            parameters: 9_000_000_000,
            architecture: ModelArchitecture(
                name: "mlx-community/gemma-2-9b-it-4bit", layerCount: 42, kvHeadCount: 8,
                headDimension: 256, hiddenSize: 3584, parameterCount: 9_000_000_000
            ),
            tasks: [.chat, .translation]
        ),
        ModelInfo(
            name: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit",
            parameters: 11_000_000_000,
            architecture: ModelArchitecture(
                name: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit", layerCount: 40, kvHeadCount: 8,
                headDimension: 128, hiddenSize: 4096, parameterCount: 11_000_000_000
            ),
            tasks: [.vision, .chat]
        )
    ]
}
