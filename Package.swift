// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VeloxQuant",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "VeloxQuantCore", targets: ["VeloxQuantCore"]),
        .library(name: "VeloxQuantRuntime", targets: ["VeloxQuantRuntime"])
    ],
    targets: [
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
)
