import XCTest
@testable import VeloxQuantRuntime

final class HardwareDetectorTests: XCTestCase {
    func testDetectReturnsWithoutCrashing() {
        let info = HardwareDetector.detect()

        XCTAssertFalse(info.chipName.isEmpty)
        XCTAssertGreaterThan(info.unifiedMemoryBytes, 0)
    }

    func testGpuCoreCountIsHonestlyNilRatherThanGuessed() {
        // No documented sysctl key exists for GPU core count across all M-series
        // generations. `HardwareDetector` must never fabricate a value here.
        let info = HardwareDetector.detect()

        XCTAssertNil(info.gpuCoreCount)
    }

    func testUnifiedMemoryGBIsDerivedFromBytes() {
        let info = HardwareInfo(
            chipName: "Apple M3 Pro",
            chipFamily: .m3,
            performanceCoreCount: 6,
            efficiencyCoreCount: 6,
            gpuCoreCount: nil,
            unifiedMemoryBytes: 34_359_738_368,
            macOSVersion: "macOS 14.0.0"
        )

        XCTAssertEqual(info.unifiedMemoryGB, 32.0, accuracy: 0.001)
    }

    func testChipFamilyMatchesSubstringInBrandString() {
        // Mirrors HardwareDetector's substring-match approach without needing real hardware:
        // AppleSiliconChip's raw values are what the private detectChipFamily(from:) matches
        // against a sysctl brand string like "Apple M3 Pro".
        XCTAssertTrue("Apple M3 Pro".contains(AppleSiliconChip.m3.rawValue))
        XCTAssertFalse("Apple M3 Pro".contains(AppleSiliconChip.m1.rawValue))
    }
}
