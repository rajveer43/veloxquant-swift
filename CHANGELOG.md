# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(pending maintainer confirmation before the first tagged release — see the build
prompt's "final note on flagged judgment calls").

## [Unreleased]

### Added
- Repo bootstrap: SwiftPM package layout (`VeloxQuantCore`, `VeloxQuantRuntime`),
  `swift-tools-version:5.9`, package-wide `platforms:` floor
  (`.iOS(.v16), .macOS(.v13), .watchOS(.v9), .tvOS(.v16), .visionOS(.v1)`), zero
  external package dependencies, SwiftLint configuration, CI workflow skeletons
  (`swift-test-macos`, `swift-test-linux`, `swiftlint`), tag-triggered release workflow.

- Phase 0: `VeloxQuantRuntime`'s `HardwareDetector.detect()` and `HardwareInfo`/
  `AppleSiliconChip`, a near-verbatim extraction of VeloxQuant-Studio's
  `HardwareService`/`HardwareInfo` — verified against real Apple Silicon (M4) hardware.
  The macOS/platform-wide module boundary is enforced two ways: every
  `VeloxQuantRuntime` source file `#error`s on non-macOS compilation (verified via a
  scratch package attempting to build `VeloxQuantRuntime` for iOS), and a scratch
  iOS-shaped consumer package (`scratch/ios-smoke/`) proves `VeloxQuantCore` alone
  builds and links for the iOS Simulator with zero `VeloxQuantRuntime` symbols
  reachable.

### Changed
- **Deviated from plan §3.2's `HardwareInfo`/`AppleSiliconChip` sketch, following
  VeloxQuant-Studio's real source instead**, per the build prompt's own instruction to
  treat a discrepancy between a planning document's sketch and Studio's actual shipping
  code the same as a Python-source discrepancy — stop and flag it, don't silently pick
  one. The plan's §3.2 code sketch names fields `chip`/`totalMemoryBytes` and specifies
  `AppleSiliconChip` as a plain (non-raw-value) enum with a `.unknown` case. Studio's
  real `HardwareInfo`/`MacChipFamily` (`VeloxQuant-Studio/VeloxQuantStudio/Models/
  HardwareInfo.swift`) instead uses `chipFamily`/`unifiedMemoryBytes` and a
  `String`-raw-value enum with no `.unknown` case (an unrecognized brand string
  substring-match simply yields `nil`, which is the behavior actually needed — nothing
  in Studio's production code has ever required a wire-decoded "unknown chip" case,
  since this type is never decoded from JSON, only constructed locally from a live
  `sysctlbyname` read). This SDK's `HardwareInfo`/`AppleSiliconChip` follow Studio's
  real field names and shape exactly (the build prompt's explicit "near-verbatim
  extraction, not reimplementation" framing for this type), not the plan's sketch. The
  plan's `chip --recommend` string-mapping note is unaffected either way — it still
  moves to the CLI-argument-builder layer in Phase 3, per both the plan and this
  build prompt.
- **Fixed a Linux CI mechanism the plan's §5.3 assumed would work but does not**:
  `swift test --filter VeloxQuantCoreTests` still resolves and builds every target in
  the manifest before filtering which tests run — including `VeloxQuantRuntime`, whose
  every source file `#error`s outside `#if os(macOS)`. Verified this failure directly
  (a real CI run failed with exactly this error) before fixing it, rather than assuming
  the plan's suggested invocation would work as written. Fixed by making
  `Package.swift`'s `products`/`targets` arrays themselves `#if os(macOS)`-conditional,
  so `VeloxQuantRuntime`/`VeloxQuantRuntimeTests` are excluded from the manifest
  entirely on non-macOS hosts — the standard SwiftPM pattern for a platform-gated
  target, and the only mechanism that actually makes a plain `swift build`/`swift test`
  work unmodified on Linux. Verified end-to-end via a local Docker `swift:5.9`
  container running the exact CI job.

### Judgment calls confirmed
- Repo location: standalone `veloxquant-swift` repo under `rajveer43`, matching the
  Go/TS/Rust/Kotlin sibling precedent, rather than a local package embedded in
  VeloxQuant-Studio's existing repo (plan §9 item 1). Confirmed with the maintainer
  before repo creation.
