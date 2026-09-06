import XCTest
@testable import VeloxQuantCore

/// Placeholder acceptance check carried forward from the Kotlin sibling SDK's Phase 0
/// discipline. Swift's `Codable` is compiler-synthesized, not reflection-based, so this SDK
/// does not face kotlinx.serialization's polymorphic-serialization reflection-fallback
/// footgun — but this test exists as a template so that when a future dynamic-key type
/// (e.g. a `JSONValue`-shaped type for `logitBias`/`chatTemplateKwargs`) is added, its
/// decoding path gets the same "does this actually decode via direct property mapping, not
/// a slow, hand-rolled `Dictionary<String, Any>` bridge" scrutiny from day one.
final class CodableDirectDecodingTests: XCTestCase {
    private struct SampleWireShape: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testSampleWireShapeDecodesViaDirectPropertyMapping() throws {
        let json = Data(#"{"name":"turboquant_rvq","count":2}"#.utf8)

        let decoded = try JSONDecoder().decode(SampleWireShape.self, from: json)

        XCTAssertEqual(decoded, SampleWireShape(name: "turboquant_rvq", count: 2))
    }
}
