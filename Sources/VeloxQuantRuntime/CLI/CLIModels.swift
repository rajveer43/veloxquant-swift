#if os(macOS)

import Foundation
import VeloxQuantCore

// Wire types for `python -m veloxquant_mlx <subcommand> --json`. Every field and raw value here
// was read off the Python source (`veloxquant_mlx/cli/*.py`, `cache/registry.py`,
// `tools/mac_recommender.py`), not guessed — see each type's doc comment for the exact origin.

/// `recommend --goal` values (`cli/recommend.py`'s `choices`).
public enum RecommendGoal: String, Codable, Sendable, CaseIterable {
    /// Balanced default.
    case everyday
    /// Maximize key-cache compression accounting.
    case maxKeyAccounting = "max_key_accounting"
    /// Fit the longest context.
    case maxContext = "max_context"
    /// Favor output quality.
    case bestQuality = "best_quality"
    /// Never grow past a fixed memory budget.
    case constantMemory = "constant_memory"
}

/// Inputs for `recommend --json` in its legacy (`--chip/--ram-gb/--model-class/--goal`) mode —
/// the mode Studio's `BenchmarkService` and the TS SDK drive. All four legacy flags are
/// **required** by the CLI (it exits with an error otherwise).
public struct RecommendCLIRequest: Sendable, Equatable {
    /// `--chip`: one of `M1`...`M4` (see `recommendChipArgument(for:)`).
    public var chip: String
    /// `--ram-gb`: one of `allowedRAMGB` (see `ramBucket(forBytes:)`).
    public var ramGB: Int
    /// `--model-class`: one of `modelClasses` (see `modelClass(forParameterCount:)`).
    public var modelClass: String
    /// `--goal`.
    public var goal: RecommendGoal
    /// `--seq-len` (CLI default 4096).
    public var sequenceLength: Int
    /// `--n-layers` (CLI default 32).
    public var layerCount: Int
    /// `--n-kv-heads` (CLI default 8).
    public var kvHeadCount: Int
    /// `--head-dim` (CLI default 128).
    public var headDimension: Int

    /// Creates a request; workload-shape fields default to the CLI's own defaults.
    public init(
        chip: String,
        ramGB: Int,
        modelClass: String,
        goal: RecommendGoal = .everyday,
        sequenceLength: Int = 4096,
        layerCount: Int = 32,
        kvHeadCount: Int = 8,
        headDimension: Int = 128
    ) {
        self.chip = chip
        self.ramGB = ramGB
        self.modelClass = modelClass
        self.goal = goal
        self.sequenceLength = sequenceLength
        self.layerCount = layerCount
        self.kvHeadCount = kvHeadCount
        self.headDimension = headDimension
    }
}

/// `recommend --json`'s top-level shape: `{"request": {...}, "recommendation": {...}}`.
public struct RecommendResponse: Codable, Sendable, Equatable {
    /// The recommendation (`RecommendResult.to_dict()`).
    public let recommendation: Recommendation

    /// Creates a response.
    public init(recommendation: Recommendation) {
        self.recommendation = recommendation
    }
}

/// Inputs for `auto-config --json` (`cli/auto_config.py`; kebab-case flags).
public struct AutoConfigCLIRequest: Sendable, Equatable {
    /// `--head-dim` (CLI default 128).
    public var headDimension: Int
    /// `--seq-len` (CLI default 4096).
    public var sequenceLength: Int
    /// `--n-layers` (CLI default 1).
    public var layerCount: Int
    /// `--batch-size` (CLI default 1).
    public var batchSize: Int
    /// `--total-memory-bytes`; `nil` lets the CLI detect it via `mx.device_info()`.
    public var totalMemoryBytes: UInt64?
    /// `--active-memory-bytes`; ignored by the CLI unless `totalMemoryBytes` is also set.
    public var activeMemoryBytes: UInt64?

    /// Creates a request with the CLI's own defaults.
    public init(
        headDimension: Int = 128,
        sequenceLength: Int = 4096,
        layerCount: Int = 1,
        batchSize: Int = 1,
        totalMemoryBytes: UInt64? = nil,
        activeMemoryBytes: UInt64? = nil
    ) {
        self.headDimension = headDimension
        self.sequenceLength = sequenceLength
        self.layerCount = layerCount
        self.batchSize = batchSize
        self.totalMemoryBytes = totalMemoryBytes
        self.activeMemoryBytes = activeMemoryBytes
    }
}

/// `auto-config --json`'s output. Port of Studio's `AutoConfigResponse`: `config` carries
/// `method`/`head_dim` plus only the selected method's own knobs.
public struct AutoConfigResponse: Decodable, Sendable, Equatable {
    /// The selected configuration.
    public let config: RecommendedConfig
    /// The CLI's explanation for the pick.
    public let reason: String

    /// `method`, `head_dim`, and every other key collected into `knobs`.
    public struct RecommendedConfig: Decodable, Sendable, Equatable {
        /// Selected compression method.
        public let method: String
        /// Head dimension the config was computed for.
        public let headDimension: Int
        /// Method-specific knobs (e.g. `bit_width_inlier`, `kivi_group_size`).
        public let knobs: [String: JSONValue]

        /// Creates a config.
        public init(method: String, headDimension: Int, knobs: [String: JSONValue]) {
            self.method = method
            self.headDimension = headDimension
            self.knobs = knobs
        }

        /// Decodes dynamically: `method`/`head_dim` are pulled out, the rest become `knobs`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var method = ""
            var headDimension = 128
            var knobs: [String: JSONValue] = [:]
            for key in container.allKeys {
                switch key.stringValue {
                case "method": method = try container.decode(String.self, forKey: key)
                case "head_dim": headDimension = try container.decode(Int.self, forKey: key)
                default: knobs[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
                }
            }
            self.init(method: method, headDimension: headDimension, knobs: knobs)
        }
    }
}

/// `methods --json`'s envelope (`cli/methods.py`).
public struct MethodsResponse: Decodable, Sendable, Equatable {
    /// Schema version (1 today).
    public let schemaVersion: Int
    /// The method `serve` uses when `--method` is omitted.
    public let defaultServeMethod: String
    /// Accounting-only caveat flag. Decoded as `decodeIfPresent(...) ?? true` — Studio's
    /// fail-toward-`true`-on-absence pattern, so a missing field never reads as a real memory win.
    public let accountingOnly: Bool
    /// The caveat, in words.
    public let accountingNote: String?
    /// Every listed method.
    public let methods: [CompressionMethod]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case defaultServeMethod = "default_serve_method"
        case accountingOnly = "accounting_only"
        case accountingNote = "accounting_note"
        case methods
    }

    /// Decodes the envelope.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        defaultServeMethod = try container.decode(String.self, forKey: .defaultServeMethod)
        accountingOnly = try container.decodeIfPresent(Bool.self, forKey: .accountingOnly) ?? true
        accountingNote = try container.decodeIfPresent(String.self, forKey: .accountingNote)
        methods = try container.decode([CompressionMethod].self, forKey: .methods)
    }
}

/// One entry of `methods --json` (`MethodInfo.to_dict()` in `cache/registry.py`). Field set is
/// Studio's `QuantizationMethod` (plan §3.4's "direct port"); `capabilities` is not modeled.
public struct CompressionMethod: Decodable, Sendable, Equatable, Identifiable {
    /// Same as `name`.
    public var id: String { name }
    /// Registry name (e.g. `turboquant_rvq`).
    public let name: String
    /// What the method does to the cache.
    public let family: MethodFamily
    /// Serving support tier.
    public let serveTier: ServeTier
    /// Human-readable tier label.
    public let serveTierLabel: String
    /// Whether `veloxquant serve` can run it at all.
    public let isServable: Bool
    /// One-line description.
    public let blurb: String
    /// `--set`-able `KVCacheConfig` fields.
    public let configFields: [String]
    /// Per-field schema for `configFields`.
    public let fieldSchema: [ConfigField]
    /// Which byte counters the method reports (wire key `coverage`).
    public let telemetryCoverage: TelemetryCoverage
    /// Human-readable coverage label.
    public let coverageLabel: String
    /// How the implementation deviates from its paper, if at all.
    public let paperDeviation: String?
    /// Whether this is an adapted (not paper-faithful) implementation.
    public let isAdapted: Bool
    /// Why it cannot be served, when `isServable` is false.
    public let unsupportedReason: String?
    /// Raw `docs_url` (kept as a string, as Studio does — a bad URL should not fail the decode).
    public let docsURLString: String?

    /// `docsURLString` as a `URL`, when present and well-formed.
    public var docsURL: URL? { docsURLString.flatMap(URL.init(string:)) }

    enum CodingKeys: String, CodingKey {
        case name, family
        case serveTier = "serve_tier"
        case serveTierLabel = "serve_tier_label"
        case isServable = "is_servable"
        case blurb
        case configFields = "config_fields"
        case fieldSchema = "field_schema"
        case telemetryCoverage = "coverage"
        case coverageLabel = "coverage_label"
        case paperDeviation = "paper_deviation"
        case isAdapted = "is_adapted"
        case unsupportedReason = "unsupported_reason"
        case docsURLString = "docs_url"
    }
}

/// `MethodFamily` in `cache/registry.py`, decoded leniently: an unrecognized value becomes
/// `.unknown` instead of failing — `[CompressionMethod]` decoding is all-or-nothing, and Studio
/// shipped exactly that bug once (issue #42) before adding this fallback.
public enum MethodFamily: Decodable, Sendable, Equatable, Hashable {
    /// Quantizes cache entries.
    case quantization
    /// Evicts tokens.
    case eviction
    /// Both.
    case hybrid
    /// A family this SDK version does not know yet.
    case unknown

    /// The wire value (`"unknown"` for `.unknown`), used for `methods --family`.
    public var rawValue: String {
        switch self {
        case .quantization: return "quantization"
        case .eviction: return "eviction"
        case .hybrid: return "hybrid"
        case .unknown: return "unknown"
        }
    }

    /// Decodes leniently (see the type's doc comment).
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "quantization": self = .quantization
        case "eviction": self = .eviction
        case "hybrid": self = .hybrid
        default: self = .unknown
        }
    }
}

/// `ServeTier` in `cache/registry.py`. `.crashes` uses the exact wire value `"crashes"` — Studio
/// once mis-modeled it as `unsupported`, which silently failed the whole `methods --json` decode.
public enum ServeTier: String, Decodable, Sendable, CaseIterable {
    /// Compressed storage is real (currently unreachable upstream).
    case honestBytes = "honest_bytes"
    /// Serves correctly; byte counts are accounting-only.
    case accountingOnly = "accounting_only"
    /// Serves correctly; prompt-cache trimming unavailable.
    case notTrimmable = "not_trimmable"
    /// Cannot be served.
    case crashes = "crashes"

    /// Every tier except `.crashes` (`ServeTier.is_servable`).
    public var isServable: Bool { self != .crashes }
}

/// `TelemetryCoverage` in `cache/registry.py`. Wire values are `keys_and_values`/`keys_only`/
/// `none`; an unrecognized value degrades to `.none` (the most conservative reading — Kotlin's
/// `toTelemetryCoverageOrNone` convention) rather than failing the decode.
public enum TelemetryCoverage: Decodable, Sendable, Equatable, Hashable {
    /// Reports keys and values (`keys_and_values`).
    case full
    /// Reports keys only (`keys_only`) — a key-only ratio is not a whole-cache ratio.
    case keysOnly
    /// Reports nothing (`none`) — "not reported" is not zero.
    case none

    /// Decodes leniently (see the type's doc comment).
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "keys_and_values": self = .full
        case "keys_only": self = .keysOnly
        default: self = .none
        }
    }
}

/// One `field_schema` entry (`describe_field()` in `cache/registry.py`), Studio's `ConfigField`.
public struct ConfigField: Decodable, Sendable, Equatable, Identifiable {
    /// Same as `name`.
    public var id: String { name }
    /// Field name (e.g. `kivi_group_size`).
    public let name: String
    /// Python type name.
    public let type: String
    /// Whether the field accepts `None`.
    public let optional: Bool
    /// Default value, if any.
    public let defaultValue: JSONValue?
    /// Help text, if any.
    public let help: String?

    enum CodingKeys: String, CodingKey {
        case name, type, optional
        case defaultValue = "default"
        case help
    }
}

/// Inputs for `profile` (always-JSON output; kebab-case flags, `cli/profile.py`).
public struct ProfileCLIRequest: Sendable, Equatable {
    /// `--model` (required).
    public var model: String
    /// `--method`; `nil` uses the CLI's default serve method.
    public var method: String?
    /// `--bits` (CLI default 2).
    public var bits: Int
    /// `--prompt`; `nil` uses the CLI's filler sentence.
    public var prompt: String?
    /// `--max-tokens`; `nil` uses the CLI default (64).
    public var maxTokens: Int?
    /// `--set FIELD=VALUE` overrides (`bit_width_inlier`/`seed` are filtered out — see
    /// `VeloxQuantCLI.serverOwnedOverrideKeys`).
    public var setOverrides: [String: String]

    /// Creates a request.
    public init(
        model: String,
        method: String? = nil,
        bits: Int = 2,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        setOverrides: [String: String] = [:]
    ) {
        self.model = model
        self.method = method
        self.bits = bits
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.setOverrides = setOverrides
    }
}

/// Inputs for `precompute` (no `--json`, writes files; **snake_case** flags, `cli/precompute.py`).
public struct PrecomputeCLIRequest: Sendable, Equatable {
    /// `--head_dim` (CLI default 128).
    public var headDimension: Int
    /// `--bits` (CLI default `[1, 2, 3, 4]`).
    public var bits: [Int]
    /// `--jl_dim` (CLI default 128).
    public var jlDimension: Int
    /// `--seed` (CLI default 42).
    public var seed: Int
    /// `--output_dir` (CLI default `./artifacts/`).
    public var outputDirectory: String

    /// Creates a request with the CLI's own defaults.
    public init(
        headDimension: Int = 128,
        bits: [Int] = [1, 2, 3, 4],
        jlDimension: Int = 128,
        seed: Int = 42,
        outputDirectory: String = "./artifacts/"
    ) {
        self.headDimension = headDimension
        self.bits = bits
        self.jlDimension = jlDimension
        self.seed = seed
        self.outputDirectory = outputDirectory
    }
}

/// Inputs for `benchmark` — the CLI's KV-cache attend() micro-benchmark (no `--json`;
/// **snake_case** flags, `cli/benchmark.py`). Deliberately not called a serving benchmark.
public struct KVCacheMicrobenchmarkRequest: Sendable, Equatable {
    /// `--method`: one of `turboquant_prod`, `turboquant_mse`, `qjl`, `polar` (CLI's `choices`).
    public var method: String
    /// `--head_dim` (CLI default 128).
    public var headDimension: Int
    /// `--bits` (CLI default 3).
    public var bits: Int
    /// `--jl_dim` (CLI default 128).
    public var jlDimension: Int
    /// `--seq_lens` (CLI default: `--seq_len`'s 1000).
    public var sequenceLengths: [Int]
    /// `--seed` (CLI default 42).
    public var seed: Int
    /// `--compare_optimized`.
    public var compareOptimized: Bool

    /// Creates a request with the CLI's own defaults.
    public init(
        method: String = "turboquant_prod",
        headDimension: Int = 128,
        bits: Int = 3,
        jlDimension: Int = 128,
        sequenceLengths: [Int] = [1000],
        seed: Int = 42,
        compareOptimized: Bool = false
    ) {
        self.method = method
        self.headDimension = headDimension
        self.bits = bits
        self.jlDimension = jlDimension
        self.sequenceLengths = sequenceLengths
        self.seed = seed
        self.compareOptimized = compareOptimized
    }
}

/// Parsed `benchmark` stdout table (`seq_len | baseline_attend_ms [| optimized_attend_ms |
/// speedup]`, `cli/benchmark.py`'s exact print format). `rawLines` is always complete.
public struct KVCacheMicrobenchmarkResult: Sendable, Equatable {
    /// One parsed table row.
    public struct Row: Sendable, Equatable {
        /// Sequence length measured.
        public let sequenceLength: Int
        /// Baseline attend() latency, ms.
        public let baselineAttendMs: Double
        /// Optimized attend() latency, ms (only with `compareOptimized`).
        public let optimizedAttendMs: Double?
        /// `baseline / optimized` (only with `compareOptimized`).
        public let speedup: Double?
    }

    /// Parsed data rows.
    public let rows: [Row]
    /// Every non-blank stdout line, verbatim.
    public let rawLines: [String]
}

/// Generic key used for dynamic-key decoding.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
