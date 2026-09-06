import Foundation

/// The `recommend --json` / `auto-config --json` recommendation payload. Direct port of
/// `VeloxQuant-Studio/VeloxQuantStudio/Services/BenchmarkService.swift`'s `RecommendResponse.
/// Recommendation` — same field set, same manual `CodingKeys` (`kvFP16MB`/
/// `kvCompressedMBEstimate` preserve the all-caps `FP16`/`MB` acronym styling
/// `.convertFromSnakeCase` cannot produce, per investigation §5.7).
///
/// Defined here in `VeloxQuantCore` even though it is only ever produced by
/// `VeloxQuantRuntime`'s CLI shell-outs (Phase 3+), because `VeloxQuantError.autopilotWontFit`
/// (Phase 1) carries it directly — Swift's two-target package shape never creates the
/// circular-module-dependency problem that forced Kotlin's equivalent type into
/// flattened primitive fields.
public struct Recommendation: Codable, Sendable, Equatable {
    public let method: String
    public let knobs: [String: JSONValue]
    public let keyAccountingRatio: Double
    public let residentSavingsLikely: Bool
    public let kvFP16MB: Double
    public let kvCompressedMBEstimate: Double
    public let warnings: [String]
    public let rationale: String

    public init(
        method: String,
        knobs: [String: JSONValue],
        keyAccountingRatio: Double,
        residentSavingsLikely: Bool,
        kvFP16MB: Double,
        kvCompressedMBEstimate: Double,
        warnings: [String],
        rationale: String
    ) {
        self.method = method
        self.knobs = knobs
        self.keyAccountingRatio = keyAccountingRatio
        self.residentSavingsLikely = residentSavingsLikely
        self.kvFP16MB = kvFP16MB
        self.kvCompressedMBEstimate = kvCompressedMBEstimate
        self.warnings = warnings
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey {
        case method, knobs
        case keyAccountingRatio = "key_accounting_ratio"
        case residentSavingsLikely = "resident_savings_likely"
        case kvFP16MB = "kv_fp16_mb"
        case kvCompressedMBEstimate = "kv_compressed_mb_estimate"
        case warnings, rationale
    }
}
