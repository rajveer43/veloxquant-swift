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
    .package(url: "https://github.com/rajveer43/veloxquant-swift", exact: "0.1.0-alpha")
]
```

Pre-release tags (`-alpha`, `-beta`, etc.) need `exact:`, not `from:` — SwiftPM's `from:` range matching only considers stable versions. Once a stable `1.0.0`-style tag exists, switch to `from: "1.0.0"`.

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
| `VeloxQuantCore` | iOS 16+, macOS 13+, watchOS 9+, tvOS 16+, visionOS 1+ | Chat/streaming HTTP client, full error model, memory estimation, conversations, structured output, embeddings, monitoring | Shipped: `chat()`/`chatStream()` + the `VeloxQuantError` hierarchy (Phase 1); `MemoryEstimator` (Go/Rust KV-cache formula, `accountingOnly` fields), `OfflineOptimizer`, curated `ModelRegistry`; `Conversation` (actor, failed turns leave history unchanged); `ResponseFormat.jsonMode`/`.jsonSchema(...)` + `chatStructured()` → `StructuredResult`; `embed()`; `Monitor` + live per-request metrics. |
| `VeloxQuantRuntime` | macOS 13+ only | Python interpreter resolution, CLI shell-outs, AutoPilot, `serve` process lifecycle, method/model listing | Shipped: `HardwareDetector.detect()` (Phase 0); `PythonEnvironment` (`VELOXQUANT_PYTHON` + Studio auto-detect); `VeloxQuantCLI` (`recommend`/`auto-config`/`methods`/`profile`/`precompute`/`benchmark`); `VeloxQuantProcess.listMethods()`/`listLocalModels()`; `AutoPilot` (`tryStart`/`start`, `plan` decision trail); `VeloxQuantProcess` (`serve` launch, readiness race, SIGINT→SIGTERM→SIGKILL stop, best-effort orphan cleanup); host/process memory samplers. Pending: `benchmarkServing()`. |

Every feature above is unit-tested against mocked boundaries (`URLProtocol` for HTTP, fake
process runners/handles for subprocesses). End-to-end behavior against a real `veloxquant serve`
on Apple Silicon has **not** yet been verified by hand for the Phase 2+ features — see
`CHANGELOG.md`.

### Runtime caveats worth knowing up front

- **Compression byte counts are accounting-only.** VeloxQuant's caches store dequantized fp16
  tensors, so `MemoryEstimate`'s `optimized*`/`saved*` figures describe compression accounting,
  not resident-memory reduction. Every estimate carries `accountingOnly`/`accountingNote`.
- **`response_format` is not enforced by the runtime.** `mlx_lm.server` ignores it;
  `chatStructured()` is a prompt-injection fallback that returns `.parsed` or `.parseFailed`.
- **`embed()` has no route on the VeloxQuant runtime today** (`mlx_lm.server` does not serve
  `/v1/embeddings`); it works against OpenAI-compatible backends that do.
- **Orphaned `serve` processes are prevented best-effort only** (`atexit` + `deinit`). A macOS
  app should also call `stop()` from `NSApplication.willTerminateNotification`.

## Requirements

- Swift 5.9 toolchain (Xcode 15+) to build.
- A discoverable Python environment with `veloxquant_mlx` installed for any feature that shells
  out to it (CLI calls, AutoPilot, `serve` process management) — macOS-only
  (`VeloxQuantRuntime`), never required for `VeloxQuantCore` consumers. `PythonEnvironment.
  autoDetect()` honors `VELOXQUANT_PYTHON` (the same override the Go/TS SDKs read), then tries
  `$VIRTUAL_ENV`, `$CONDA_PREFIX`, Homebrew/system paths, and your login shell's `python3`.
  `listLocalModels()` needs no Python at all (it scans the Hugging Face cache directly).

## Building

```sh
swift build
swift test
```

## License

MIT — see `LICENSE`.
