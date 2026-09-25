import XCTest
@testable import VeloxQuantCore

/// Ports of `veloxquant-go/optimize/optimizer_test.go`, Rust's `OptimizationService` tests, and
/// `veloxquant-go/models`' recommendation behavior.
final class OfflineOptimizerTests: XCTestCase {
    private let architecture = ModelArchitecture(
        name: "test-model", layerCount: 32, kvHeadCount: 8, headDimension: 128,
        hiddenSize: 4096, parameterCount: 7_000_000_000
    )

    func testRecommendDerivesAProfileFromAvailableMemory() throws {
        let recommendation = try OfflineOptimizer.recommend(OptimizationRequest(
            architecture: architecture, contextLength: 4096, availableMemoryBytes: 8_000_000_000
        ))
        XCTAssertGreaterThan(recommendation.compressionBits, 0)
        XCTAssertEqual(recommendation.contextLength, 4096)
        XCTAssertFalse(recommendation.reason.isEmpty)
        XCTAssertTrue(recommendation.isOfflineEstimate)
        XCTAssertTrue(recommendation.accountingOnly)
        XCTAssertLessThanOrEqual(recommendation.estimatedMemoryAfter, recommendation.estimatedMemoryBefore)
    }

    func testRecommendHonorsForcedProfile() throws {
        let recommendation = try OfflineOptimizer.recommend(OptimizationRequest(
            architecture: architecture, contextLength: 4096, profile: .speed
        ))
        XCTAssertEqual(recommendation.profile, .speed)
        XCTAssertEqual(recommendation.compressionBits, 16)
        XCTAssertEqual(recommendation.reason, "using explicitly requested \"speed\" profile")
    }

    func testAbundantMemoryPicksSpeedAndTightMemoryPicksMemoryProfile() throws {
        let abundant = try OfflineOptimizer.recommend(OptimizationRequest(
            architecture: architecture, contextLength: 4096, availableMemoryBytes: UInt64.max
        ))
        XCTAssertEqual(abundant.profile, .speed)

        let estimate = try MemoryEstimator.estimate(MemoryRequest(architecture: architecture, contextLength: 4096))
        let tight = try OfflineOptimizer.recommend(OptimizationRequest(
            architecture: architecture, contextLength: 4096, availableMemoryBytes: estimate.optimizedTotalBytes + 1
        ))
        XCTAssertEqual(tight.profile, .memory)
        XCTAssertEqual(tight.compressionBits, 4)

        let unknown = try OfflineOptimizer.recommend(
            OptimizationRequest(architecture: architecture, contextLength: 4096)
        )
        XCTAssertEqual(unknown.profile, .maximumContext)
    }

    func testRecommendRejectsZeroContextLength() {
        let request = OptimizationRequest(architecture: architecture, contextLength: 0)
        XCTAssertThrowsError(try OfflineOptimizer.recommend(request))
    }

    func testProfileRawValuesAndPrecisionsMatchGo() {
        XCTAssertEqual(OptimizationProfile.allCases.map(\.rawValue), ["speed", "balanced", "memory", "maximum-context"])
        XCTAssertEqual(OptimizationProfile.allCases.map(\.precision), [.fp16, .int8, .int4, .int4])
    }

    // MARK: - Model registry (Go's models.RecommendScored)

    func testCuratedRegistryMatchesGoStaticRegistry() {
        let names = ModelRegistry.curated.map(\.name)
        XCTAssertEqual(names, [
            "mlx-community/Qwen3-8B-4bit",
            "mlx-community/Qwen3-Coder-4bit",
            "mlx-community/gemma-2-9b-it-4bit",
            "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit"
        ])
    }

    func testRecommendScoredFiltersByTaskAndRanksRecommendedFirst() throws {
        let registry = ModelRegistry()
        let coding = try registry.recommendScored(task: .coding, availableMemoryBytes: 64 * 1_073_741_824)
        XCTAssertEqual(coding.map(\.info.name), ["mlx-community/Qwen3-Coder-4bit"])
        XCTAssertTrue(coding[0].reason.contains("memory headroom at 8192-token context"))

        let chat = try registry.recommendScored(task: .chat, availableMemoryBytes: 64 * 1_073_741_824)
        XCTAssertEqual(chat.first?.info.name, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(chat.count, 3)
    }

    func testRecommendScoredDropsModelsThatDoNotFit() throws {
        let registry = ModelRegistry()
        XCTAssertTrue(try registry.recommendScored(task: .chat, availableMemoryBytes: 1_000_000).isEmpty)
    }

    func testRecommendScoredWithoutBudgetKeepsEveryTaskMatch() throws {
        let all = try ModelRegistry().recommendScored(task: nil, availableMemoryBytes: 0)
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all[0].info.recommended)
        XCTAssertTrue(all[0].reason.contains("no memory budget"))
    }

    // MARK: - JSONValue nesting (closes Phase 1's flagged schema gap)

    func testJSONValueRoundTripsNestedSchema() throws {
        let json = Data((#"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"#
            + #""required":["tags"],"n":1,"x":1.5,"b":true,"z":null}"#).utf8)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: json)
        XCTAssertEqual(decoded["required"], .array([.string("tags")]))
        XCTAssertEqual(decoded["n"], .int(1))
        XCTAssertEqual(decoded["x"], .double(1.5))
        XCTAssertEqual(decoded["b"], .bool(true))
        XCTAssertEqual(decoded["z"], .null)
        guard case .object(let properties)? = decoded["properties"],
              case .object(let tags)? = properties["tags"] else {
            return XCTFail("expected nested objects")
        }
        XCTAssertEqual(tags["items"], .object(["type": .string("string")]))

        let reencoded = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded, decoded)
    }

    func testResponseFormatHelpersEncodeOpenAIShape() throws {
        let jsonModeData = try JSONEncoder().encode(ResponseFormat.jsonMode)
        let jsonMode = try JSONSerialization.jsonObject(with: jsonModeData) as? [String: Any]
        XCTAssertEqual(jsonMode?["type"] as? String, "json_object")

        let schema = ResponseFormat.jsonSchema(name: "person", schema: ["type": .string("object")], strict: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        XCTAssertEqual(encoded?["type"] as? String, "json_schema")
        let inner = encoded?["json_schema"] as? [String: Any]
        XCTAssertEqual(inner?["name"] as? String, "person")
        XCTAssertEqual(inner?["strict"] as? Bool, true)
        XCTAssertEqual((inner?["schema"] as? [String: Any])?["type"] as? String, "object")
    }
}
