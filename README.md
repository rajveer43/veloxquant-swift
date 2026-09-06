# veloxquant-swift

Swift SDK for [VeloxQuant](https://github.com/rajveer43/veloxquant-mlx) — the
Apple-Silicon-only MLX KV-cache compression engine. Sibling to the TypeScript, Go, Rust, and
Kotlin client SDKs.

**Status: pre-alpha, under active phased construction.** See `CHANGELOG.md` for what's landed
so far.

## Installation

Swift Package Manager, via this repo's git URL — there is no group-ID/namespace registration
step for Swift, and no publish step exists for SwiftPM at all (the package is identified by its
git URL directly):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rajveer43/veloxquant-swift", from: "0.1.0")
]
```

Then depend on the product(s) you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "VeloxQuantCore", package: "veloxquant-swift"),
        // Add VeloxQuantRuntime only from a macOS target — see the platform note below.
        .product(name: "VeloxQuantRuntime", package: "veloxquant-swift")
    ]
)
```

iOS/iPadOS/watchOS/tvOS/visionOS targets should depend on `VeloxQuantCore` only.
`VeloxQuantRuntime` (process management, CLI shell-outs, AutoPilot) is macOS-only — `Process`
is not available on those platforms at all (an App Store sandboxing rule, not a missing-API
gap), and `VeloxQuantRuntime` will fail to compile on any non-macOS destination with an
explicit `#error` rather than a confusing missing-symbol error.

## Targets

| Target | Platforms | Purpose | Status |
|---|---|---|---|
| `VeloxQuantCore` | iOS 16+, macOS 13+, watchOS 9+, tvOS 16+, visionOS 1+ | Chat/streaming HTTP client, full error model, memory estimation, conversations, structured output, embeddings, monitoring | Bootstrap in progress (Phase 0). |
| `VeloxQuantRuntime` | macOS 13+ only | Python interpreter resolution, CLI shell-outs, AutoPilot, `serve` process lifecycle, method/model listing | Bootstrap in progress (Phase 0). |

## Requirements

- Swift 5.9 toolchain (Xcode 15+) to build.
- A discoverable Python environment with `veloxquant_mlx` installed for any feature that shells
  out to it (AutoPilot, `serve` process management) — macOS-only (`VeloxQuantRuntime`), never
  required for `VeloxQuantCore` consumers.

## Building

```sh
swift build
swift test
```

## License

MIT — see `LICENSE`.
