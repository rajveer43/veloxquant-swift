import Foundation

/// A memory estimation query for a specific model, context length, and precision.
///
/// Port of Go's `memory.Request` / Rust's `MemoryRequest`. `optimizedPrecision` defaults to
/// `.int4`, matching both siblings (Go's zero-value fallback, Rust's `MemoryRequest::new`).
public struct MemoryRequest: Sendable, Equatable {
    /// The model architecture to estimate memory for.
    public var architecture: ModelArchitecture
    /// Sequence length, in tokens, the KV cache must hold.
    public var contextLength: Int
    /// Precision used for the naive (unoptimized) estimate.
    public var precision: Precision
    /// Precision VeloxQuant would use for the KV cache when compression is applied.
    public var optimizedPrecision: Precision

    /// Creates a request. `precision` defaults to `.fp16` and `optimizedPrecision` to `.int4`.
    public init(
        architecture: ModelArchitecture,
        contextLength: Int,
        precision: Precision = .fp16,
        optimizedPrecision: Precision = .int4
    ) {
        self.architecture = architecture
        self.contextLength = contextLength
        self.precision = precision
        self.optimizedPrecision = optimizedPrecision
    }
}

/// The result of a memory estimation: the unoptimized ("naive") footprint and the
/// VeloxQuant-optimized footprint.
///
/// Every byte field is a field-for-field port of Go's `memory.Estimate` / Rust's
/// `MemoryEstimate`. `accountingOnly`/`accountingNote` are additions required by this SDK's
/// plan (§3.3) and non-goal 2 ("never describe compression byte-counts as real memory
/// reduction"): they are real, always-populated fields, not doc comments.
public struct MemoryEstimate: Sendable, Equatable {
    /// Estimated model weight memory, in bytes.
    public let modelMemoryBytes: UInt64
    /// Estimated uncompressed KV-cache memory, in bytes.
    public let kvCacheMemoryBytes: UInt64
    /// Fixed runtime overhead, in bytes (`MemoryEstimator.runtimeOverheadBytes`).
    public let runtimeOverheadBytes: UInt64
    /// Total memory without VeloxQuant optimization, in bytes.
    public let totalMemoryBytes: UInt64

    /// Estimated KV-cache memory after VeloxQuant compression, in bytes.
    public let optimizedKVBytes: UInt64
    /// Total memory with VeloxQuant optimization, in bytes.
    public let optimizedTotalBytes: UInt64
    /// Bytes saved by optimization (`total - optimizedTotal`, floored at 0).
    public let savedBytes: UInt64
    /// Percentage of `totalMemoryBytes` saved by optimization.
    public let savedPercent: Double

    /// Human-readable description of the compression strategy, e.g. `"4-bit KV cache compression"`.
    public let recommendedStrategy: String

    /// Always `true` today: VeloxQuant's caches store dequantized fp16 tensors at runtime, so the
    /// `optimized*`/`saved*` figures are compression *accounting*, not resident-memory reduction.
    public let accountingOnly: Bool
    /// The caveat behind `accountingOnly`, in words.
    public let accountingNote: String

    /// Whether the **unoptimized** footprint fits in `available` bytes.
    ///
    /// Deliberately checks `totalMemoryBytes`, not `optimizedTotalBytes`: because compression is
    /// accounting-only today (`accountingOnly == true`), the uncompressed total is the honest
    /// resident-memory figure. Use `optimizedTotalBytes` directly if you want the accounting view.
    public func fits(inAvailableBytes available: UInt64) -> Bool {
        totalMemoryBytes <= available
    }
}

/// Thrown by `MemoryEstimator.estimate(_:)` for an unusable request.
///
/// Go returns a plain `fmt.Errorf` and Rust `VeloxQuantError::InvalidRequest` for the same
/// condition. This SDK's `VeloxQuantError` models network/runtime failures only, so pure-
/// computation input validation gets its own small error type instead of a new case there.
public enum MemoryEstimatorError: Error, LocalizedError, Sendable, Equatable {
    /// `contextLength` was zero or negative.
    case nonPositiveContextLength(modelName: String, contextLength: Int)

    /// Human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .nonPositiveContextLength(modelName, contextLength):
            return "estimate memory for \(modelName): context length must be positive (got \(contextLength))"
        }
    }
}

/// Pure, offline, closed-form KV-cache and model memory accounting.
///
/// The one deliberate exception to "never reimplement the Python engine" (plan §3.3): it works
/// instantly on every Apple platform, including watchOS, with no network or process access.
/// The arithmetic is a line-for-line port of Go's `memory` package
/// (`veloxquant-go/memory/estimator.go`, `kv_cache.go`, `recommendation.go`) and Rust's
/// `veloxquant-memory` crate (`estimator.rs`, `kv_cache.rs`, `compression.rs`,
/// `recommendation.rs`) — both siblings agree exactly, including truncating (not rounding)
/// float-to-integer conversions, which this port preserves via `UInt64(_:)` truncation.
public enum MemoryEstimator {
    /// Conservative fixed estimate of the inference runtime's own overhead (buffers, framework,
    /// activation scratch space) beyond weights and KV cache: 512 MiB, matching Go's
    /// `runtimeOverheadBytes` and Rust's `RUNTIME_OVERHEAD_BYTES`.
    public static let runtimeOverheadBytes: UInt64 = 512 * 1024 * 1024

    /// The accounting-only caveat, worded exactly as `veloxquant methods --json`'s own
    /// `accounting_note` (`veloxquant_mlx/cli/methods.py`), so this SDK has one honesty
    /// message, not a drifting paraphrase.
    public static let accountingNote =
        "Compression is accounting-only: caches store dequantized fp16 tensors, so reported byte "
        + "counts do not correspond to runtime memory reduction."

    /// Computes uncompressed KV-cache memory in bytes:
    ///
    ///     KV Cache Memory = Layers × Tokens × KV Heads × Head Dim × 2 × BytesPerElement
    ///
    /// The factor of 2 accounts for storing both keys and values. Returns 0 (rather than
    /// throwing) if any architecture dimension or the context length is not positive — the same
    /// contract as Go's `EstimateKVCacheBytes` and Rust's `estimate_kv_cache_bytes`.
    public static func kvCacheBytes(
        architecture: ModelArchitecture,
        contextLength: Int,
        precision: Precision
    ) -> UInt64 {
        guard architecture.layerCount > 0,
              architecture.kvHeadCount > 0,
              architecture.headDimension > 0,
              contextLength > 0
        else { return 0 }

        let elements = Double(architecture.layerCount)
            * Double(contextLength)
            * Double(architecture.kvHeadCount)
            * Double(architecture.headDimension)
            * 2
        return UInt64(elements * precision.bytesPerElement)
    }

    /// Returns `uncompressedBytes` scaled by a known compression `ratio` (compressed /
    /// uncompressed), for estimation purposes. A ratio outside `(0, 1]` is treated as "no
    /// compression" — Go's `ApplyCompression` / Rust's `apply_compression_ratio`.
    public static func applyCompression(_ uncompressedBytes: UInt64, ratio: Double) -> UInt64 {
        guard ratio > 0, ratio <= 1 else { return uncompressedBytes }
        return UInt64(Double(uncompressedBytes) * ratio)
    }

    /// Estimates model, KV-cache, and total memory for `request`, both unoptimized and with
    /// VeloxQuant compression at `request.optimizedPrecision`.
    ///
    /// - Throws: `MemoryEstimatorError.nonPositiveContextLength` if `contextLength <= 0`.
    public static func estimate(_ request: MemoryRequest) throws -> MemoryEstimate {
        guard request.contextLength > 0 else {
            throw MemoryEstimatorError.nonPositiveContextLength(
                modelName: request.architecture.name,
                contextLength: request.contextLength
            )
        }

        let modelMemory = modelMemoryBytes(request.architecture, precision: request.precision)
        let kvBytes = kvCacheBytes(
            architecture: request.architecture,
            contextLength: request.contextLength,
            precision: request.precision
        )
        let optimizedKV = kvCacheBytes(
            architecture: request.architecture,
            contextLength: request.contextLength,
            precision: request.optimizedPrecision
        )

        let total = modelMemory + kvBytes + runtimeOverheadBytes
        let optimizedTotal = modelMemory + optimizedKV + runtimeOverheadBytes

        var saved: UInt64 = 0
        var savedPercent: Double = 0
        if total > optimizedTotal {
            saved = total - optimizedTotal
            savedPercent = Double(saved) / Double(total) * 100
        }

        return MemoryEstimate(
            modelMemoryBytes: modelMemory,
            kvCacheMemoryBytes: kvBytes,
            runtimeOverheadBytes: runtimeOverheadBytes,
            totalMemoryBytes: total,
            optimizedKVBytes: optimizedKV,
            optimizedTotalBytes: optimizedTotal,
            savedBytes: saved,
            savedPercent: savedPercent,
            recommendedStrategy: "\(request.optimizedPrecision.bits)-bit KV cache compression",
            accountingOnly: true,
            accountingNote: accountingNote
        )
    }

    /// Chooses a KV-cache precision given available memory versus the naive estimate, returning
    /// the precision and a human-readable reason. Port of Go's `memory.RecommendStrategy` /
    /// Rust's `recommend_strategy`, reason strings verbatim.
    public static func recommendStrategy(
        for estimate: MemoryEstimate,
        availableMemoryBytes: UInt64
    ) -> (precision: Precision, reason: String) {
        if availableMemoryBytes == 0 {
            return (.int4, "available memory unknown; defaulting to the most memory-efficient option")
        }
        if estimate.totalMemoryBytes <= availableMemoryBytes {
            return (.fp16, "sufficient memory available; no compression required")
        }
        if estimate.optimizedTotalBytes <= availableMemoryBytes {
            return (
                .int4,
                "uncompressed footprint exceeds available memory; 4-bit KV compression fits within budget"
            )
        }
        return (
            .int4,
            "even with maximum compression, memory is tight; consider a smaller model or shorter context"
        )
    }

    /// Model weight memory from parameter count and precision, falling back to an
    /// architecture-derived parameter estimate when `parameterCount` is 0.
    static func modelMemoryBytes(_ architecture: ModelArchitecture, precision: Precision) -> UInt64 {
        let params = architecture.parameterCount > 0
            ? architecture.parameterCount
            : estimatedParameterCount(architecture)
        return UInt64(Double(params) * precision.bytesPerElement)
    }

    /// Coarse transformer parameter count (~`12 × hidden_size²` per layer, the standard
    /// order-of-magnitude for attention + MLP blocks) — fallback only, as in Go/Rust.
    static func estimatedParameterCount(_ architecture: ModelArchitecture) -> UInt64 {
        guard architecture.layerCount > 0, architecture.hiddenSize > 0 else { return 0 }
        let hidden = UInt64(architecture.hiddenSize)
        return 12 * hidden * hidden * UInt64(architecture.layerCount)
    }
}
