#if os(macOS)

import Foundation

/// Reads Apple Silicon chip name, core counts, and unified memory via direct `sysctlbyname(3)`
/// syscalls — no `Process`, no `sysctl(1)` shell-out.
///
/// This is a near-verbatim extraction of
/// `VeloxQuant-Studio/VeloxQuantStudio/Services/HardwareService.swift`: same sysctl key names
/// (`machdep.cpu.brand_string`, `hw.memsize`, `hw.perflevel0.physicalcpu`,
/// `hw.perflevel1.physicalcpu`), same honest `gpuCoreCount: nil`.
public enum HardwareDetector {
    /// Detects the current Mac's hardware. Runs without crashing on any macOS host; the values
    /// it reports are only meaningfully verifiable on real Apple Silicon hardware.
    public static func detect() -> HardwareInfo {
        let chipName = sysctlString("machdep.cpu.brand_string") ?? fallbackChipName()
        let memoryBytes = sysctlUInt64("hw.memsize") ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let perfCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let effCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0

        return HardwareInfo(
            chipName: chipName,
            chipFamily: detectChipFamily(from: chipName),
            performanceCoreCount: perfCores,
            efficiencyCoreCount: effCores,
            gpuCoreCount: nil,
            unifiedMemoryBytes: memoryBytes,
            macOSVersion: macOSVersionString()
        )
    }

    private static func fallbackChipName() -> String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Unknown (non-Apple Silicon)"
        #endif
    }

    private static func detectChipFamily(from chipName: String) -> AppleSiliconChip? {
        for family in AppleSiliconChip.allCases where chipName.contains(family.rawValue) {
            return family
        }
        return nil
    }

    private static func macOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - sysctl helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
