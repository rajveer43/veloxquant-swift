import Foundation

/// A point-in-time snapshot of memory and inference metrics.
///
/// Field set is Go's `monitor.Metrics` (`veloxquant-go/monitor/metrics.go`) / Rust's
/// `veloxquant_monitor::Metrics`, plus the plan's (§3.11) `timestamp` and
/// `residentMemoryBytes`. Unlike Go/Rust (whose zero values cannot distinguish "not measured"
/// from "zero"), every measurement here is optional: `nil` means "this sampler/request did not
/// measure it", never "zero" — e.g. `residentMemoryBytes` is `nil` unless produced by
/// `VeloxQuantRuntime`'s process-scoped sampler.
public struct Metrics: Sendable, Equatable {
    /// When this snapshot was taken.
    public var timestamp: Date
    /// System memory in use, in bytes.
    public var memoryUsedBytes: UInt64?
    /// System memory available, in bytes.
    public var memoryAvailableBytes: UInt64?
    /// Resident memory of the local `veloxquant serve` process, in bytes (macOS-only sampler).
    public var residentMemoryBytes: UInt64?
    /// Generation throughput of the most recent request, in tokens (or content chunks, for
    /// streams — see `VeloxQuantClient.chatStream(_:)`) per second.
    public var tokensPerSecond: Double?
    /// Time to first token of the most recent streamed request.
    public var timeToFirstToken: Duration?
    /// Context length in use, in tokens.
    public var contextLength: Int?
    /// KV-cache memory in use, in bytes.
    public var kvCacheBytes: UInt64?
    /// Compression ratio in effect (compressed / uncompressed).
    public var compressionRatio: Double?

    /// Creates a snapshot; every measurement defaults to `nil` ("not measured").
    public init(
        timestamp: Date = Date(),
        memoryUsedBytes: UInt64? = nil,
        memoryAvailableBytes: UInt64? = nil,
        residentMemoryBytes: UInt64? = nil,
        tokensPerSecond: Double? = nil,
        timeToFirstToken: Duration? = nil,
        contextLength: Int? = nil,
        kvCacheBytes: UInt64? = nil,
        compressionRatio: Double? = nil
    ) {
        self.timestamp = timestamp
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstToken = timeToFirstToken
        self.contextLength = contextLength
        self.kvCacheBytes = kvCacheBytes
        self.compressionRatio = compressionRatio
    }

    /// `timeToFirstToken` in milliseconds (the plan's `timeToFirstTokenMs` spelling).
    public var timeToFirstTokenMs: Double? {
        guard let timeToFirstToken else { return nil }
        let components = timeToFirstToken.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

/// Produces a `Metrics` snapshot on demand. Port of Go's `monitor.Sampler`; a sampler that
/// throws simply skips that tick, as in Go's `sampleAndNotify`.
public protocol MetricsSampler: Sendable {
    /// Takes one snapshot.
    func sample() async throws -> Metrics
}

/// Adapts a closure to `MetricsSampler` — Go's `monitor.SamplerFunc`.
public struct MetricsSamplerFunction: MetricsSampler {
    private let body: @Sendable () async throws -> Metrics

    /// Wraps `body`.
    public init(_ body: @escaping @Sendable () async throws -> Metrics) {
        self.body = body
    }

    /// Calls the wrapped closure.
    public func sample() async throws -> Metrics {
        try await body()
    }
}

/// The platform-wide default sampler: timestamps only, every measurement `nil`.
///
/// Go's default samples host memory via its `system` package. `VeloxQuantCore` runs on
/// iOS/watchOS/tvOS/visionOS/Linux, where no portable "available system memory" API exists,
/// so the platform-wide default measures nothing it can't measure honestly. On macOS,
/// `VeloxQuantRuntime` provides a host-memory sampler and a per-process RSS sampler.
public struct TimestampSampler: MetricsSampler {
    /// Creates the sampler.
    public init() {}

    /// Returns `Metrics(timestamp: Date())`.
    public func sample() async throws -> Metrics {
        Metrics()
    }
}
