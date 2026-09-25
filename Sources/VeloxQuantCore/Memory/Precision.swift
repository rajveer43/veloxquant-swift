import Foundation

/// Numeric format used to store model weights or KV-cache entries.
///
/// Direct port of Go's `memory.Precision` (`veloxquant-go/memory/profiles.go`) and Rust's
/// `veloxquant_memory::Precision` (`crates/veloxquant-memory/src/estimator.rs`): same four
/// cases, same raw values (`"fp16"`, `"fp8"`, `"int8"`, `"int4"`), same bytes-per-element and
/// bit widths. Like Rust (and unlike Go's free-form `string` type), an invalid precision is
/// unrepresentable, so Go's "unknown precision falls back to FP16" branch has no Swift
/// equivalent to port.
public enum Precision: String, Codable, Sendable, CaseIterable {
    /// 16-bit floating point (2 bytes/element).
    case fp16
    /// 8-bit floating point (1 byte/element).
    case fp8
    /// 8-bit integer quantization (1 byte/element).
    case int8
    /// 4-bit integer quantization (0.5 bytes/element).
    case int4

    /// Storage size, in bytes, of a single scalar at this precision.
    public var bytesPerElement: Double {
        switch self {
        case .fp16: return 2
        case .fp8: return 1
        case .int8: return 1
        case .int4: return 0.5
        }
    }

    /// Bit width, used when reporting a recommended compression strategy.
    public var bits: Int {
        switch self {
        case .fp16: return 16
        case .fp8: return 8
        case .int8: return 8
        case .int4: return 4
        }
    }
}

/// The shape of a transformer model, sufficient to compute weight and KV-cache memory.
///
/// Field-for-field port of Go's `memory.Architecture` / Rust's `ModelArchitecture`. Rust's
/// `name` field (used only for error messages) is carried here too.
public struct ModelArchitecture: Codable, Sendable, Equatable, Hashable {
    /// Human-readable model name, used only for error messages/context.
    public var name: String
    /// Number of transformer layers.
    public var layerCount: Int
    /// Number of key/value attention heads.
    public var kvHeadCount: Int
    /// Dimension of each attention head.
    public var headDimension: Int
    /// Model hidden size, used to approximate the parameter count when `parameterCount` is 0.
    public var hiddenSize: Int
    /// Total parameter count, if known. When 0, approximated from `layerCount`/`hiddenSize`.
    public var parameterCount: UInt64

    /// Creates an architecture description.
    public init(
        name: String = "",
        layerCount: Int,
        kvHeadCount: Int,
        headDimension: Int,
        hiddenSize: Int = 0,
        parameterCount: UInt64 = 0
    ) {
        self.name = name
        self.layerCount = layerCount
        self.kvHeadCount = kvHeadCount
        self.headDimension = headDimension
        self.hiddenSize = hiddenSize
        self.parameterCount = parameterCount
    }

    enum CodingKeys: String, CodingKey {
        case name
        case layerCount = "num_layers"
        case kvHeadCount = "num_kv_heads"
        case headDimension = "head_dim"
        case hiddenSize = "hidden_size"
        case parameterCount = "parameter_count"
    }
}
