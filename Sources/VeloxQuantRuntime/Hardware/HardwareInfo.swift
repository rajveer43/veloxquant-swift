#if os(macOS)

import Foundation

/// Snapshot of the local Mac's hardware, read via `sysctlbyname(3)`. Purely local — no
/// Python round-trip needed for this.
///
/// This is a near-verbatim extraction of
/// `VeloxQuant-Studio/VeloxQuantStudio/Models/HardwareInfo.swift`, not a reimplementation.
/// `gpuCoreCount` is honestly `nil`: no documented sysctl key exists for GPU core count
/// across all M-series generations, and this type does not guess one.
public struct HardwareInfo: Equatable, Sendable {
    public let chipName: String
    public let chipFamily: AppleSiliconChip?
    public let performanceCoreCount: Int
    public let efficiencyCoreCount: Int
    public let gpuCoreCount: Int?
    public let unifiedMemoryBytes: UInt64
    public let macOSVersion: String

    public init(
        chipName: String,
        chipFamily: AppleSiliconChip?,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        gpuCoreCount: Int?,
        unifiedMemoryBytes: UInt64,
        macOSVersion: String
    ) {
        self.chipName = chipName
        self.chipFamily = chipFamily
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.macOSVersion = macOSVersion
    }

    /// Unified memory expressed in GB (binary, 1024^3 bytes per GB), for display purposes.
    public var unifiedMemoryGB: Double {
        Double(unifiedMemoryBytes) / 1_073_741_824
    }
}

/// Apple Silicon chip generation. Pro/Max/Ultra are RAM/core-count tiers, not separate
/// chips, per the Python engine's `mac_recommender.py`.
///
/// Note: the "what string does `veloxquant recommend --chip` accept" mapping (Studio's
/// `recommenderArgument`) deliberately does **not** live on this type — it lands in
/// `VeloxQuantRuntime`'s CLI-argument-builder layer in Phase 3, keeping "what is true about
/// this Mac" separate from "what string does this one CLI flag want."
public enum AppleSiliconChip: String, CaseIterable, Sendable {
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
