// swift-tools-version:5.9
import PackageDescription

// VeloxQuantRuntime (and its test target) is macOS-only — every file under
// Sources/VeloxQuantRuntime/ #errors when compiled for any other OS (build prompt Phase 0
// item 2). `swift test`, even with `--filter`, still builds every target the manifest
// declares before running the requested subset — a plain `--filter VeloxQuantCoreTests` on
// Linux still trips VeloxQuantRuntime's #error. Excluding the target from the manifest
// entirely on non-macOS hosts (rather than relying on `--filter`/`--target` alone) is the
// standard SwiftPM pattern for this, and is what actually makes `swift test` on Linux build
// and run cleanly.
#if os(macOS)
let products: [Product] = [
    .library(name: "VeloxQuantCore", targets: ["VeloxQuantCore"]),
    .library(name: "VeloxQuantRuntime", targets: ["VeloxQuantRuntime"])
]
let targets: [Target] = [
    .target(
        name: "VeloxQuantCore",
        path: "Sources/VeloxQuantCore"
    ),
    .target(
        name: "VeloxQuantRuntime",
        dependencies: ["VeloxQuantCore"],
        path: "Sources/VeloxQuantRuntime"
    ),
    .testTarget(
        name: "VeloxQuantCoreTests",
        dependencies: ["VeloxQuantCore"],
        path: "Tests/VeloxQuantCoreTests"
    ),
    .testTarget(
        name: "VeloxQuantRuntimeTests",
        dependencies: ["VeloxQuantRuntime"],
        path: "Tests/VeloxQuantRuntimeTests"
    )
]
#else
let products: [Product] = [
    .library(name: "VeloxQuantCore", targets: ["VeloxQuantCore"])
]
let targets: [Target] = [
    .target(
        name: "VeloxQuantCore",
        path: "Sources/VeloxQuantCore"
    ),
    .testTarget(
        name: "VeloxQuantCoreTests",
        dependencies: ["VeloxQuantCore"],
        path: "Tests/VeloxQuantCoreTests"
    )
]
#endif

let package = Package(
    name: "VeloxQuant",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: products,
    targets: targets
)
