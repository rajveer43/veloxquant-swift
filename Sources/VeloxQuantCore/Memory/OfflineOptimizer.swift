import Foundation

/// A VeloxQuant optimization strategy trading off speed, memory usage, and context length.
///
/// Port of Go's `optimize.Profile` (`veloxquant-go/optimize/profiles.go`) and Rust's
/// `OptimizationProfile`; raw values match Go's strings exactly.
public enum OptimizationProfile: String, Codable, Sendable, CaseIterable {
    /// No KV compression (fp16).
    case speed
    /// 8-bit KV compression.
    case balanced
    /// 4-bit KV compression, chosen because memory is tight.
    case memory
    /// 4-bit KV compression, chosen to maximize context length.
    case maximumContext = "maximum-context"

    /// The KV-cache precision this profile targets (Go's `precisionForProfile`).
    public var precision: Precision {
        switch self {
        case .speed: return .fp16
        case .balanced: return .int8
        case .memory, .maximumContext: return .int4
        }
    }
}

/// An offline optimization recommendation query. Port of Go's `optimize.Request`.
public struct OptimizationRequest: Sendable, Equatable {
    /// The model to recommend a strategy for.
    public var architecture: ModelArchitecture
    /// Target context length, in tokens.
    public var contextLength: Int
    /// Memory available on the host, in bytes. 0 means unknown.
    public var availableMemoryBytes: UInt64
    /// If set, forces this profile instead of deriving one from available memory.
    public var profile: OptimizationProfile?

    /// Creates a request.
    public init(
        architecture: ModelArchitecture,
        contextLength: Int,
        availableMemoryBytes: UInt64 = 0,
        profile: OptimizationProfile? = nil
    ) {
        self.architecture = architecture
        self.contextLength = contextLength
        self.availableMemoryBytes = availableMemoryBytes
        self.profile = profile
    }
}

/// VeloxQuant's offline suggested optimization strategy. Port of Go's
/// `optimize.Recommendation` / Rust's `OptimizationRecommendation`.
public struct OptimizationRecommendation: Sendable, Equatable {
    /// The profile this recommendation targets.
    public let profile: OptimizationProfile
    /// Human-readable name of the compression method.
    public let compressionMethod: String
    /// Bit width of the recommended KV-cache compression.
    public let compressionBits: Int
    /// Estimated total memory before optimization, in bytes.
    public let estimatedMemoryBefore: UInt64
    /// Estimated total memory after optimization, in bytes (accounting view, see `accountingOnly`).
    public let estimatedMemoryAfter: UInt64
    /// Context length this recommendation was computed for.
    public let contextLength: Int
    /// Why this recommendation was chosen.
    public let reason: String
    /// Always `true`: this is the pure-computation, client-side estimate, not the Python CLI's
    /// `recommend` ruleset. Mirrors Kotlin's `Recommendation.isOfflineEstimate` (plan §3.6).
    public let isOfflineEstimate: Bool
    /// Always `true` today — see `MemoryEstimate.accountingOnly`.
    public let accountingOnly: Bool
}

/// Offline (no CLI, no network) optimization-profile selection, usable on every Apple platform.
///
/// Port of Go's `optimize.Optimizer.Recommend` (`veloxquant-go/optimize/optimizer.go`) and
/// Rust's `OptimizationService::recommend`. This is the lower-fidelity substitute the plan
/// (§3.6) names for non-macOS callers that cannot run `VeloxQuantRuntime`'s CLI-backed
/// `AutoPilot`: it uses only `MemoryEstimator`'s closed-form arithmetic, never the Python
/// engine's own ruleset, and says so via `isOfflineEstimate`.
public enum OfflineOptimizer {
    /// Produces an optimization recommendation, using `request.profile` if set, otherwise
    /// deriving one from `request.availableMemoryBytes`.
    ///
    /// - Throws: `MemoryEstimatorError.nonPositiveContextLength` if `contextLength <= 0`.
    public static func recommend(_ request: OptimizationRequest) throws -> OptimizationRecommendation {
        let baseEstimate = try MemoryEstimator.estimate(MemoryRequest(
            architecture: request.architecture,
            contextLength: request.contextLength,
            precision: .fp16,
            optimizedPrecision: .int4
        ))

        let precision: Precision
        let reason: String
        let profile: OptimizationProfile
        if let forced = request.profile {
            precision = forced.precision
            reason = "using explicitly requested \"\(forced.rawValue)\" profile"
            profile = forced
        } else {
            let strategy = MemoryEstimator.recommendStrategy(
                for: baseEstimate,
                availableMemoryBytes: request.availableMemoryBytes
            )
            precision = strategy.precision
            reason = strategy.reason
            profile = profileFor(
                precision: precision,
                estimate: baseEstimate,
                availableMemoryBytes: request.availableMemoryBytes
            )
        }

        let optimized = try MemoryEstimator.estimate(MemoryRequest(
            architecture: request.architecture,
            contextLength: request.contextLength,
            precision: .fp16,
            optimizedPrecision: precision
        ))

        return OptimizationRecommendation(
            profile: profile,
            compressionMethod: "VeloxQuant KV-cache compression",
            compressionBits: precision.bits,
            estimatedMemoryBefore: optimized.totalMemoryBytes,
            estimatedMemoryAfter: optimized.optimizedTotalBytes,
            contextLength: request.contextLength,
            reason: reason,
            isOfflineEstimate: true,
            accountingOnly: true
        )
    }

    /// Infers the profile best matching a precision chosen by `recommendStrategy` — Rust's
    /// `profile_for_precision` (which, unlike Go's string-typed switch, maps `.fp8` to
    /// `.balanced` alongside `.int8`; unreachable from `recommendStrategy` either way).
    static func profileFor(
        precision: Precision,
        estimate: MemoryEstimate,
        availableMemoryBytes: UInt64
    ) -> OptimizationProfile {
        switch precision {
        case .fp16:
            return .speed
        case .int8, .fp8:
            return .balanced
        case .int4:
            // Overflow-safe form of Go's `available < optimizedTotal*2` (Go's uint64 would wrap
            // silently; Swift would trap).
            let doubled = estimate.optimizedTotalBytes.multipliedReportingOverflow(by: 2)
            let threshold = doubled.overflow ? UInt64.max : doubled.partialValue
            if availableMemoryBytes > 0,
               estimate.optimizedTotalBytes > 0,
               availableMemoryBytes < threshold {
                return .memory
            }
            return .maximumContext
        }
    }
}
