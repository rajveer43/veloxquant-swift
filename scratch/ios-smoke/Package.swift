// swift-tools-version:5.9
// TODO Phase 8: promote this into a real iOS smoke-build CI job (plan §7 Phase 8 item 2)
// rather than this throwaway local scratch consumer.
import PackageDescription

let package = Package(
    name: "IOSShapedConsumer",
    platforms: [.iOS(.v16)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "IOSShapedConsumer",
            dependencies: [
                .product(name: "VeloxQuantCore", package: "veloxquant-swift")
                // Deliberately NOT depending on VeloxQuantRuntime — this is the Phase 0
                // dependency-graph-enforcement proof (build prompt §Phase 0 item 3).
            ]
        )
    ]
)
