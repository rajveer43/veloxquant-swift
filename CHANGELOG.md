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

- Phase 1: `VeloxQuantCore`'s `VeloxQuantClient` (plain `init`, `baseURL` defaulting to
  `http://127.0.0.1:8000`), `chat()`/`chatStream()`, the full request/response wire
  model (`ChatRequest` with every field from investigation §1.3, `Message`
  enum-with-payload, `ChatResponse`, `ChatChunk`, `Usage`, `ToolCall`/`ToolDefinition`,
  `ResponseFormat`, `JSONValue` ported verbatim from Studio's
  `QuantizationMethod.swift`), and the complete 11-case `VeloxQuantError` hierarchy
  (`Error`, `LocalizedError`, `Sendable`) with the full 404-dispatch logic
  (`generationFailed`/`unexpectedRoute`/`malformedErrorResponse`/`serverError`,
  inspecting response bodies rather than dispatching on status code alone).
  `chatStream()` hand-rolls SSE parsing over `URLSession`'s byte stream: skips
  `:`-prefixed keepalive comments and blank lines, handles the usage-only final frame
  (empty `choices: []`, populated `usage`), stops on `[DONE]`. 15 `URLProtocol`-mocked
  unit tests cover every error-dispatch branch and streaming shape from investigation
  §1.4/§1.5, plus an exhaustiveness test proving `VeloxQuantError`'s `switch` compiles
  with no `default:` branch. `Recommendation` (referenced but never field-sketched in
  the plan's §4) was sourced directly from VeloxQuant-Studio's real
  `BenchmarkService.swift` `RecommendResponse.Recommendation` type rather than guessed.

- Phase 2 — memory estimation (`VeloxQuantCore/Memory/`, every Apple platform + Linux):
  `MemoryEstimator.estimate(_:)`, `kvCacheBytes(architecture:contextLength:precision:)`,
  `applyCompression(_:ratio:)`, `recommendStrategy(for:availableMemoryBytes:)`, plus `Precision`,
  `ModelArchitecture`, `MemoryRequest`, `MemoryEstimate`. The arithmetic is a line-for-line port
  of Go's `memory` package and Rust's `veloxquant-memory` crate, which agree exactly:
  `layers × tokens × kv_heads × head_dim × 2 × bytes_per_element`, model weights from parameter
  count (falling back to `12 × hidden² × layers`), a fixed 512 MiB runtime overhead, `saved`
  floored at 0, and truncating (not rounding) float→integer conversion. `MemoryEstimate` also
  carries the plan's required `accountingOnly`/`accountingNote` as real, always-populated
  fields. Also ported: Go's `optimize` package as `OfflineOptimizer`/`OptimizationProfile`
  (`isOfflineEstimate == true`, the plan's §3.6 non-macOS substitute for AutoPilot) and Go's
  curated four-model registry + `RecommendScored` ranking as `ModelRegistry`. 15 unit tests
  pin exact byte values, including a static cross-check against the Python recommender's own
  `kv_fp16_mb` (512.0 at the CLI's default workload).

- Phase 3 — Python interpreter resolution + one-shot CLI shell-outs (`VeloxQuantRuntime`):
  `PythonEnvironment` (`resolveInterpreterPath`, `validate`, `autoDetect`), a mockable
  `ProcessRunning` boundary with `FoundationProcessRunner`, and `VeloxQuantCLI` wrapping
  `recommend --json`, `auto-config --json`, `methods --json`, `profile`, `precompute`, and the
  `benchmark` KV-cache micro-benchmark (`runKvCacheMicrobenchmark`), each built from a pure,
  unit-tested `...Arguments(for:)` function. Every flag was checked against
  `veloxquant_mlx/cli/*.py`: kebab-case for `recommend`/`auto-config`/`serve`/`profile`,
  snake_case for `precompute`/`benchmark`. Wire types (`RecommendResponse`,
  `AutoConfigResponse`, `MethodsResponse`, `CompressionMethod`, `MethodFamily` with lenient
  `.unknown`, `ServeTier` with the exact `"crashes"` value, `TelemetryCoverage`, `ConfigField`)
  follow Studio's `QuantizationMethod.swift`/`AutoConfigService.swift`, with regression tests
  modeled on Studio's two historical decode bugs. `VeloxQuantProcess.listMethods()` and
  `listLocalModels()` live in `VeloxQuantRuntime` from the start (the placement Kotlin had to
  correct mid-build).

- Phase 4 — AutoPilot + conversations. `Conversation` (`VeloxQuantCore`, an `actor`) ports Go's
  `NewConversation`/`Send`/`SendStream` contract: a failed turn — error status, mid-stream
  decode failure, or an abandoned stream — leaves `history` unchanged, verified by dedicated
  `URLProtocol` tests. `AutoPilot` (`VeloxQuantRuntime`) offers `tryStart` (sealed
  `AutoPilotOutcome`) and `start` (throws `VeloxQuantError.autopilotWontFit` with the identical
  payload — tested directly), and returns an `AutoPilotSession` whose `plan` records every
  decision: hardware and host memory, the selected model and why, context length, an offline
  memory estimate, a 15% safety margin, the exact `recommend` inputs/outputs, any forced
  won't-fit warnings, the serve method/bits, the `auto-config` fallback if one was used, an
  ordered `decisions` trail, and a ready-made `serveConfig`.

- Phase 5 — `serve` process lifecycle. `VeloxQuantProcess` (`actor`) launches
  `python -m veloxquant_mlx serve` through a mockable `ServeProcessLaunching`/
  `ServeProcessHandle` boundary (`FoundationServeProcessLauncher`: `Pipe` +
  `readabilityHandler`, Studio's pattern), resolves readiness by racing the `VELOXQUANT_READY`
  handshake scan against process exit, a `readyTimeout`, and a priming task (poll
  `GET /health`, then a `max_tokens: 1` chat request with backoff), exposes a `client`
  pre-wired to the handshake's host/port, and stops with SIGINT → SIGTERM → SIGKILL.
  `ServeConfig`/`ServeReadyPayload` use `serve.py`'s real flags and handshake schema. Includes
  the build prompt's required regression test: the fake emits the handshake **only** in
  response to the priming request, so `start()` succeeds only if priming works.

- Phase 6 — structured output + embeddings (`VeloxQuantCore`). `ResponseFormat.jsonMode` and
  `ResponseFormat.jsonSchema(name:schema:strict:)` (Go's `JSONMode()`/`JSONSchema(...)`
  helpers), carrying Go's documented caveat that `mlx_lm.server` does not enforce
  `response_format`. `chatStructured(_:format:as:)` returns `StructuredResult<T>`
  (`.parsed(T, raw:)`/`.parseFailed(raw:error:)`) and never throws for a non-conforming reply.
  `embed(_:)` sends OpenAI's `/v1/embeddings` shape with `EmbedInput.single`/`.batch` (Go's
  "string or []string").

- Monitoring (build prompt Phase 7, monitoring half). `Monitor` ports Go's `monitor.Monitor`
  (idempotent `start`/`stop`, immediate first sample, a failing sample skips its tick,
  `report(_:)`, `latest`, callback `subscribe(_:)`) plus the plan's `updates()`
  `AsyncStream<Metrics>`. `VeloxQuantClient.monitor(interval:sampler:)` attaches it so every
  `chat()`/`chatStream()` pushes live `tokensPerSecond`/`timeToFirstToken`, merged onto the
  last sample's memory fields, exactly as Go's `Client.Monitor`. `VeloxQuantRuntime` adds
  `HostMemorySampler`, `ProcessMetricsSampler` (RSS via `proc_pidinfo`), and
  `VeloxQuantProcess.monitor(interval:)`.

- Test suite: 126 tests (65 `VeloxQuantCoreTests`, 61 `VeloxQuantRuntimeTests`), all against
  mocked boundaries; `swift build`/`swift test` and `swiftlint lint --strict` clean on macOS;
  `VeloxQuantCore` also builds for the iOS Simulator via `xcodebuild`.

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
- **Found and fixed two independent `swift-corelibs-foundation` (Linux) platform bugs
  neither the plan nor investigation anticipated**, both discovered only once Phase 1's
  networking code actually ran on Linux, not via code review:
  1. `URLSession.data(for:)`/`.bytes(for:)` (the async convenience APIs the plan's §3.1
     code sketch uses directly) are not implemented on Linux at all — confirmed absent
     on both the `swift:5.9` and `swift:5.10` official Docker images. Fixed with
     `URLSessionCompat.swift`: `vqData(for:)`/`vqBytes(for:)` extension methods that
     resolve to the native async APIs unchanged on Apple platforms, and to a
     delegate-based shim on Linux — `chat()`/`chatStream()`'s call sites are identical
     on every platform. `bytes(for:)`'s Linux fallback buffers the full response before
     replaying it as a byte sequence (loses true incremental delivery, but SSE frames
     still parse identically line-by-line); accepted since `VeloxQuantRuntime`,
     streaming's most latency-sensitive real consumer, is macOS-only anyway.
  2. Independently, `URLSession.dataTask(with:completionHandler:)` — the older
     callback-based API Linux *does* implement — only delivers the **last**
     `URLProtocol.didLoad` chunk to its completion handler, not the accumulated
     concatenation of every chunk a custom `URLProtocol` sent (verified directly with a
     minimal two-chunk repro against the `swift:5.9` image). This silently truncated
     `chat()`'s response body in the initial version of the Linux shim. Fixed by
     routing through `URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)`
     instead, which does accumulate correctly (also verified directly) — this bypasses
     the completion-handler API's accumulation bug entirely rather than working around
     it. Also required a `swift-tools-version:5.9`-compatible replacement
     (`MockHandlerBox`, an `@unchecked Sendable` box) for `nonisolated(unsafe)` in the
     test target's `MockURLProtocol`, since that attribute requires Swift 5.10+.
  All 15 `VeloxQuantCoreTests` (11 excluding `VeloxQuantRuntimeTests`, which is
  macOS-only) pass on both `macos-14` and a local `swift:5.9` Linux container, verified
  directly rather than assumed from the macOS pass alone.

- **Resolved conflicts between this task's direction and the build prompt/plan, deliberately
  and per item** (the task asked for Go/Rust semantics; the build prompt and plan, written
  earlier for this repo, sketch several of the same features differently). Where they
  disagreed, both are recorded here rather than one silently winning:
  1. **Memory estimation follows Go/Rust, not plan §3.3's `estimate(workload:config:)`
     sketch** (Kotlin's `WorkloadSpec`/`CompressionConfig` shape). Go and Rust ship identical
     arithmetic and a model-memory/optimized/saved-percent result the task asked for; plan
     §3.3's shape has no model weights at all. Kept from the plan: `accountingOnly`/
     `accountingNote` as real fields and `fits(inAvailableBytes:)`, which deliberately checks
     the *unoptimized* total because compression is accounting-only. Not ported: a batch-size
     dimension (neither Go nor Rust has one). A non-positive context length throws a small
     `MemoryEstimatorError` (Go returns a plain error, Rust `InvalidRequest`) instead of adding
     a network-flavored case to `VeloxQuantError`.
  2. **The task named "the Conversation type in veloxquant-core" in the Rust SDK; there is
     none** (checked every crate — Rust has no conversation type, and its `veloxquant-monitor`
     documents periodic sampling as not yet implemented). `Conversation` and `Monitor` are
     therefore ported from Go, with Kotlin's `Conversation` confirming the same failed-turn
     contract.
  3. **Interpreter resolution combines Go's order with Studio's auto-detection.**
     `resolveInterpreterPath` is Go's `ResolvePythonInterpreter` verbatim (explicit →
     `$VELOXQUANT_PYTHON` → `python3`); `autoDetect` honors that same override first (and
     fails loudly if an explicit override doesn't validate), then runs plan §3.13's port of
     Studio's `PythonEnvironmentService` candidates, ending on Go's bare `python3`. Every
     candidate is validated by importing `veloxquant_mlx` (Go does not validate).
     Subcommands run as `<python> -m veloxquant_mlx ...` (plan/Studio), **not** a `veloxquant`
     console script on `PATH` (Go/Kotlin).
  4. **AutoPilot is a synthesis, not a pick.** Hardware inspection, registry-ranked model
     selection (or a pinned/custom model), the 8192-token default context, the 15% safety
     margin, and the `plan` trail are Go's `Client.AutoPilot`. The compression strategy is
     **not** computed locally: it comes from the real `recommend --json` CLI with TS's
     won't-fit pattern and TS's `methods --servable-only` check, falling back to `auto-config`
     — the TS/Kotlin/Studio architecture the plan (§3.6, non-goal 11) commits to. Go's pure-Go
     profile choice is available separately as `OfflineOptimizer`. `start()` throws
     `VeloxQuantError.autopilotWontFit` rather than plan §3.6's standalone `AutopilotFitError`,
     so callers catch one error type; `AutopilotFitError.asVeloxQuantError` guarantees the
     payloads are identical (tested).
- **Did not copy four Kotlin runtime behaviors that don't match the real Python CLI**, verified
  against `turboquant_mac_implementation` source (reported so they can be fixed in
  `veloxquant-kotlin` too):
  1. Kotlin's `recommend` omits the legacy-mode flags the CLI requires (`--chip`, `--ram-gb`,
     `--model-class`) and passes `--batch-size`, which `recommend` doesn't accept.
  2. Kotlin decodes `methods --json` as a bare array; the CLI prints an envelope object
     (`schema_version`, `default_serve_method`, `accounting_only`, `methods: [...]`).
  3. Kotlin maps telemetry coverage from `"FULL"`; the wire values are `keys_and_values`/
     `keys_only`/`none`.
  4. Kotlin's `serve` builder emits `--max_tokens`/`--temperature`/`--top_p`/
     `--prompt_cache_size`; `serve.py`'s argparse only accepts `--max-tokens`/`--temp`/
     `--top-p`/`--prompt-cache-size`. (Its `precompute` builder similarly passes flags
     `precompute.py` doesn't define.)
  Kotlin also treats `resident_savings_likely == false` as "won't fit". This SDK uses only TS's
  warning pattern: running the real recommender shows the default `everyday` goal returns
  `resident_savings_likely: false`, so Kotlin's rule would reject AutoPilot's default path on
  every Mac.
- **Fixed a latent deadlock in Studio's `ProcessRunner` while porting it**: Studio reads
  stdout/stderr only after `waitUntilExit()`, which blocks forever once a child writes more
  than the ~64 KiB pipe buffer (reachable with `methods --json`). `FoundationProcessRunner`
  drains both pipes while the process runs (tested with 300 KB of output), observes exit via
  `terminationHandler`, and terminates the child if the calling task is cancelled.
- **Shutdown differs from Studio's `stop()` in two small ways**: it returns as soon as the
  process exits instead of always sleeping the full grace period, and it adds Go's final
  `SIGKILL` if `SIGTERM` is also ignored. Orphan cleanup adds a process-wide `atexit` hook
  (SIGINT to every live `serve` PID on normal exit) on top of the plan's `deinit` hook. Both
  stay best-effort (crash/`SIGKILL`/force-quit are not covered) — see the judgment call below.
- **`VeloxQuantError` grew four cases**: `cliCommandFailed`, `malformedCLIOutput`,
  `modelNotFound` (Go's `ErrModelNotFound`), `noModelFits` (Go's `ErrInsufficientMemory`). No
  Phase 1 case described these honestly (reusing `serveProcessExited` for a one-shot CLI
  failure, for example, would mislead). **Source-breaking** for exhaustive `switch`es; the
  exhaustiveness test was updated.
- **`JSONValue` gained `.array` and `.object`**, closing the nested-schema gap Phase 1 flagged
  on `FunctionDefinition.parameters`/`ResponseFormat.JSONSchema.schema`. `.array` matches
  Studio's own later addition; the decode order is unchanged and array/object are tried last.
  **Source-breaking** for exhaustive `switch`es over `JSONValue`.
- Smaller Swift-idiom or wire-driven choices: `Conversation` serializes overlapping turns
  (actor reentrancy would otherwise let two concurrent turns build on stale history — Go is
  simply "not safe for concurrent use") and keeps a reply's `toolCalls`; embeddings decode
  `usage` into `EmbeddingUsage` (OpenAI's embeddings usage has no `completion_tokens`, which
  chat's `Usage` requires); `Metrics` fields are optional so "not measured" is never zero; the
  default `Monitor` interval is Go's 5 s (the plan sketched 1 s); non-streaming `chat()`
  reports `timeToFirstToken: nil` where Go reports 0; streamed TTFT is measured from the
  validated response, as in Go. `chatStructured` strips markdown code fences before decoding
  (TS's `parseResponseFormat`) and does no other repair. `listLocalModels()` takes no
  `PythonEnvironment` (plan §3.4's sketch had one; it is a filesystem scan, like Go's
  `ScanLocal`) and counts regular files only, so HF-cache snapshot symlinks aren't
  double-counted. AutoPilot maps hardware onto `recommend`'s fixed buckets conservatively
  (RAM rounds **down** to an allowed `--ram-gb`, parameter count rounds **up** to a
  `--model-class`, M5 → `M4` per Studio's `recommenderArgument`).

### Judgment calls confirmed
- Repo location: standalone `veloxquant-swift` repo under `rajveer43`, matching the
  Go/TS/Rust/Kotlin sibling precedent, rather than a local package embedded in
  VeloxQuant-Studio's existing repo (plan §9 item 1). Confirmed with the maintainer
  before repo creation.

### Judgment calls pending maintainer confirmation
The build prompt gates several of these phases on maintainer confirmation. This work was done
without that confirmation, so the defaults below are **provisional**:
- **Interpreter resolution + `-m veloxquant_mlx` invocation** (plan §9 item 2): chose the
  plan's Studio-derived design, extended with Go's `VELOXQUANT_PYTHON` override.
- **AutoPilot's shell-out commitment** (build prompt Phase 4 gate): kept shell-out for the
  compression strategy; Go-style model selection is additive.
- **Orphan-cleanup risk level** (plan §9 item 5): best-effort `atexit` + `deinit`, no PID file.

### Not yet done
- `benchmarkServing()` (build prompt Phase 7), and Phase 8 (required Linux CI, a watchOS/
  visionOS smoke build — the watchOS SDK isn't installed on the build machine — ATS docs,
  and a sample app).
- The live drift-guard test comparing `MemoryEstimator` with a real `recommend --json` run, and
  every hardware-gated manual check (real `serve` launch/readiness/shutdown, real
  interpreter detection). All Phase 2+ behavior here is verified against mocks only.
- The Linux (`swift:5.9`) CI leg was not run locally for this change (Docker unavailable).
  `VeloxQuantCore` uses only APIs already exercised on Linux in Phase 1, plus Swift 5.9
  stdlib concurrency types.
- `VeloxQuantClient.defaultModel` is still not applied by `chat()`/`chatStream()` (Phase 1
  behavior); `Conversation` and `embed()` do fall back to it.
