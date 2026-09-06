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

### Judgment calls confirmed
- Repo location: standalone `veloxquant-swift` repo under `rajveer43`, matching the
  Go/TS/Rust/Kotlin sibling precedent, rather than a local package embedded in
  VeloxQuant-Studio's existing repo (plan §9 item 1). Confirmed with the maintainer
  before repo creation.
