import XCTest
@testable import VeloxQuantCore

/// Ports of `veloxquant-go/memory/*_test.go` and `veloxquant-rs/crates/veloxquant-memory`'s
/// unit tests, plus exact-value checks pinning the formula and truncation behavior.
final class MemoryEstimatorTests: XCTestCase {
    private let architecture = ModelArchitecture(
        name: "test-model",
        layerCount: 32,
        kvHeadCount: 8,
        headDimension: 128,
        hiddenSize: 4096,
        parameterCount: 7_000_000_000
    )

    // MARK: - KV cache formula

    func testKVCacheBytesMatchesFormulaForFP16() {
        // 32 layers × 4096 tokens × 8 KV heads × 128 head dim × 2 (K+V) × 2 bytes
        let expected: UInt64 = 32 * 4096 * 8 * 128 * 2 * 2
        let actual = MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: 4096, precision: .fp16)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(expected, 536_870_912)
    }

    /// Static drift guard against the Python engine: `veloxquant_mlx.tools.mac_recommender.
    /// estimate_kv_fp16_mb(32, 8, 128, 4096)` — `recommend`'s `kv_fp16_mb` at the CLI's default
    /// workload — returned 512.0 when run against the local `turboquant_mac_implementation`
    /// checkout. (The live CLI cross-check the plan asks for still needs a real Python env.)
    func testFP16KVMatchesPythonRecommenderKVFP16MB() {
        let bytes = MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: 4096, precision: .fp16)
        XCTAssertEqual(Double(bytes) / (1024 * 1024), 512.0)
    }

    func testInt4IsQuarterOfFP16() {
        let fp16 = MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: 4096, precision: .fp16)
        let int4 = MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: 4096, precision: .int4)
        XCTAssertEqual(int4, fp16 / 4)
        XCTAssertEqual(int4, UInt64(Double(32 * 4096 * 8 * 128 * 2) * 0.5))
    }

    func testKVCacheBytesIsZeroForZeroContextOrEmptyArchitecture() {
        XCTAssertEqual(MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: 0, precision: .fp16), 0)
        XCTAssertEqual(MemoryEstimator.kvCacheBytes(architecture: architecture, contextLength: -5, precision: .fp16), 0)
        let empty = ModelArchitecture(layerCount: 0, kvHeadCount: 0, headDimension: 0)
        XCTAssertEqual(MemoryEstimator.kvCacheBytes(architecture: empty, contextLength: 4096, precision: .fp16), 0)
    }

    func testKVCacheBytesTruncatesFractionalBytesLikeGoAndRust() {
        // 1 × 1 × 1 × 1 × 2 × 0.5 = 1.0; 1 × 3 × 1 × 1 × 2 × 0.5 = 3.0 — then an odd count at int4.
        let tiny = ModelArchitecture(layerCount: 1, kvHeadCount: 1, headDimension: 1)
        XCTAssertEqual(MemoryEstimator.kvCacheBytes(architecture: tiny, contextLength: 1, precision: .int4), 1)
        XCTAssertEqual(MemoryEstimator.applyCompression(1001, ratio: 0.5), 500) // 500.5 truncates
    }

    // MARK: - Precision

    func testPrecisionBytesPerElementAndBits() {
        XCTAssertEqual(Precision.fp16.bytesPerElement, 2)
        XCTAssertEqual(Precision.fp8.bytesPerElement, 1)
        XCTAssertEqual(Precision.int8.bytesPerElement, 1)
        XCTAssertEqual(Precision.int4.bytesPerElement, 0.5)
        XCTAssertEqual(Precision.allCases.map(\.bits), [16, 8, 8, 4])
        XCTAssertEqual(Precision.allCases.map(\.rawValue), ["fp16", "fp8", "int8", "int4"])
    }

    // MARK: - Estimate

    func testEstimateMatchesGoAndRustExactly() throws {
        let estimate = try MemoryEstimator.estimate(MemoryRequest(architecture: architecture, contextLength: 4096))

        XCTAssertEqual(estimate.modelMemoryBytes, 14_000_000_000)
        XCTAssertEqual(estimate.kvCacheMemoryBytes, 536_870_912)
        XCTAssertEqual(estimate.runtimeOverheadBytes, 512 * 1024 * 1024)
        XCTAssertEqual(estimate.totalMemoryBytes, 14_000_000_000 + 536_870_912 + 536_870_912)
        XCTAssertEqual(estimate.optimizedKVBytes, 134_217_728)
        XCTAssertEqual(estimate.optimizedTotalBytes, 14_000_000_000 + 134_217_728 + 536_870_912)
        XCTAssertEqual(estimate.savedBytes, 536_870_912 - 134_217_728)
        XCTAssertEqual(estimate.savedPercent, Double(402_653_184) / Double(15_073_741_824) * 100, accuracy: 1e-12)
        XCTAssertEqual(estimate.recommendedStrategy, "4-bit KV cache compression")
    }

    func testEstimateDefaultsOptimizedPrecisionToInt4() throws {
        let withDefault = try MemoryEstimator.estimate(MemoryRequest(architecture: architecture, contextLength: 4096))
        let explicit = try MemoryEstimator.estimate(
            MemoryRequest(architecture: architecture, contextLength: 4096, precision: .fp16, optimizedPrecision: .int4)
        )
        XCTAssertEqual(withDefault, explicit)
    }

    func testEstimateThrowsForNonPositiveContextLength() {
        let request = MemoryRequest(architecture: architecture, contextLength: 0)
        XCTAssertThrowsError(try MemoryEstimator.estimate(request)) { error in
            XCTAssertEqual(
                error as? MemoryEstimatorError,
                .nonPositiveContextLength(modelName: "test-model", contextLength: 0)
            )
        }
    }

    func testEstimateFallsBackToArchitectureDerivedParameterCount() throws {
        var noParams = architecture
        noParams.parameterCount = 0
        let estimate = try MemoryEstimator.estimate(MemoryRequest(architecture: noParams, contextLength: 2048))
        // 12 × 4096² × 32 layers × 2 bytes
        XCTAssertEqual(estimate.modelMemoryBytes, 12 * 4096 * 4096 * 32 * 2)
    }

    func testNoSavingsWhenOptimizedPrecisionIsNotSmaller() throws {
        let estimate = try MemoryEstimator.estimate(
            MemoryRequest(architecture: architecture, contextLength: 4096, precision: .int4, optimizedPrecision: .fp16)
        )
        XCTAssertEqual(estimate.savedBytes, 0)
        XCTAssertEqual(estimate.savedPercent, 0)
    }

    func testAccountingCaveatIsAlwaysPopulated() throws {
        for precision in Precision.allCases {
            for optimized in Precision.allCases {
                let estimate = try MemoryEstimator.estimate(MemoryRequest(
                    architecture: architecture, contextLength: 1024, precision: precision, optimizedPrecision: optimized
                ))
                XCTAssertTrue(estimate.accountingOnly)
                XCTAssertTrue(estimate.accountingNote.contains("accounting-only"))
            }
        }
    }

    func testFitsChecksTheUnoptimizedTotal() throws {
        let estimate = try MemoryEstimator.estimate(MemoryRequest(architecture: architecture, contextLength: 4096))
        XCTAssertTrue(estimate.fits(inAvailableBytes: estimate.totalMemoryBytes))
        // Enough for the accounting-only optimized figure, but not the honest resident figure.
        XCTAssertFalse(estimate.fits(inAvailableBytes: estimate.optimizedTotalBytes))
    }

    // MARK: - Compression ratio

    func testApplyCompression() {
        XCTAssertEqual(MemoryEstimator.applyCompression(1000, ratio: 0.5), 500)
        XCTAssertEqual(MemoryEstimator.applyCompression(1000, ratio: 0), 1000)
        XCTAssertEqual(MemoryEstimator.applyCompression(1000, ratio: -1), 1000)
        XCTAssertEqual(MemoryEstimator.applyCompression(1000, ratio: 1.5), 1000)
        XCTAssertEqual(MemoryEstimator.applyCompression(1000, ratio: 1), 1000)
    }

    // MARK: - Strategy recommendation (Go's RecommendStrategy table)

    func testRecommendStrategy() throws {
        let estimate = try MemoryEstimator.estimate(MemoryRequest(architecture: architecture, contextLength: 4096))
        let cases: [(UInt64, Precision)] = [
            (0, .int4),
            (UInt64.max, .fp16),
            (estimate.optimizedTotalBytes + 1, .int4),
            (1_000_000_000, .int4)
        ]
        for (available, expected) in cases {
            let result = MemoryEstimator.recommendStrategy(for: estimate, availableMemoryBytes: available)
            XCTAssertEqual(result.precision, expected, "available=\(available)")
            XCTAssertFalse(result.reason.isEmpty)
        }
    }
}
