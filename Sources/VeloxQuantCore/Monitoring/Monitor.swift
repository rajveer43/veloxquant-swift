import Foundation

/// Periodically samples `Metrics` and notifies subscribers, merging in live per-request
/// inference metrics pushed from `chat()`/`chatStream()`.
///
/// Port of Go's `monitor.Monitor` (`veloxquant-go/monitor/monitor.go`): `start()`/`stop()` are
/// idempotent, the first sample is taken immediately on `start()`, a sampler error skips that
/// tick, `report(_:)` pushes an out-of-band update whether or not the monitor is started, and
/// `latest` returns the most recent snapshot. Go's callback `Subscribe` is offered as
/// `subscribe(_:)`; `updates()` additionally exposes the plan's (§3.11) non-throwing
/// `AsyncStream<Metrics>`.
///
/// All methods are safe to call from any thread or task.
public final class Monitor: @unchecked Sendable {
    /// Go's `defaultMonitorInterval`: 5 seconds.
    public static let defaultInterval: Duration = .seconds(5)

    /// The sampling interval.
    public let interval: Duration

    private let sampler: MetricsSampler
    private let lock = NSLock()
    private var latestMetrics: Metrics?
    private var lastSample: Metrics?
    private var callbacks: [@Sendable (Metrics) -> Void] = []
    private var continuations: [UUID: AsyncStream<Metrics>.Continuation] = [:]
    private var samplingTask: Task<Void, Never>?

    /// Creates a monitor sampling `sampler` every `interval` once `start()` is called. A
    /// non-positive interval falls back to `defaultInterval`, as in Go's `monitor.New`.
    public init(sampler: MetricsSampler = TimestampSampler(), interval: Duration = Monitor.defaultInterval) {
        self.sampler = sampler
        self.interval = interval > .zero ? interval : Monitor.defaultInterval
    }

    deinit {
        samplingTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// Whether periodic sampling is running.
    public var isRunning: Bool {
        withLock { samplingTask != nil }
    }

    /// The most recent snapshot (sampled or reported), or `nil` before the first one.
    public var latest: Metrics? {
        withLock { latestMetrics }
    }

    /// Begins periodic sampling. A no-op if already running.
    public func start() {
        withLock {
            guard samplingTask == nil else { return }
            samplingTask = Task { [weak self, sampler, interval] in
                while !Task.isCancelled {
                    if let metrics = try? await sampler.sample() {
                        self?.publish(metrics, isSample: true)
                    }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// Stops periodic sampling. Safe to call multiple times; subscribers stay registered and
    /// still receive `report(_:)` updates.
    public func stop() {
        let task = withLock { () -> Task<Void, Never>? in
            let task = samplingTask
            samplingTask = nil
            return task
        }
        task?.cancel()
    }

    /// Pushes an out-of-band update to subscribers immediately (Go's `Monitor.Report`).
    public func report(_ metrics: Metrics) {
        publish(metrics, isSample: false)
    }

    /// Registers a callback invoked with every new snapshot (Go's `Monitor.Subscribe`).
    public func subscribe(_ callback: @escaping @Sendable (Metrics) -> Void) {
        withLock { callbacks.append(callback) }
    }

    /// Returns a stream of every future snapshot. The stream ends when the monitor is
    /// deallocated; cancelling iteration unregisters it.
    public func updates() -> AsyncStream<Metrics> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Metrics>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in
            self?.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        withLock { continuations[id] = continuation }
        return stream
    }

    /// Reports a completed request's inference metrics, merged onto the most recent periodic
    /// sample's memory fields — Go's `Client.Monitor` metrics sink.
    func reportInference(tokensPerSecond: Double?, timeToFirstToken: Duration?) {
        var metrics = withLock { lastSample } ?? Metrics()
        metrics.timestamp = Date()
        metrics.tokensPerSecond = tokensPerSecond
        metrics.timeToFirstToken = timeToFirstToken
        report(metrics)
    }

    private func publish(_ metrics: Metrics, isSample: Bool) {
        typealias Targets = ([@Sendable (Metrics) -> Void], [AsyncStream<Metrics>.Continuation])
        let (callbacks, continuations) = withLock { () -> Targets in
            latestMetrics = metrics
            if isSample { lastSample = metrics }
            return (self.callbacks, Array(self.continuations.values))
        }
        for callback in callbacks {
            callback(metrics)
        }
        for continuation in continuations {
            continuation.yield(metrics)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Lock-protected holder for the client's live-metrics sink, so `VeloxQuantClient` can stay a
/// `final class` of `let` properties (and `Sendable`) while a monitor is attached later.
final class MetricsSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var monitor: Monitor?

    func attach(_ monitor: Monitor) {
        lock.lock()
        self.monitor = monitor
        lock.unlock()
    }

    func report(tokensPerSecond: Double?, timeToFirstToken: Duration?) {
        lock.lock()
        let monitor = self.monitor
        lock.unlock()
        monitor?.reportInference(tokensPerSecond: tokensPerSecond, timeToFirstToken: timeToFirstToken)
    }
}

extension VeloxQuantClient {
    /// Returns a `Monitor` sampling `sampler` every `interval` (5 s by default, Go's default).
    /// Between samples, every `chat()`/`chatStream()` call made through this client also pushes
    /// a live update carrying that request's `tokensPerSecond`/`timeToFirstToken`, merged onto
    /// the most recent sample's memory fields — Go's `Client.Monitor` behavior.
    ///
    /// As in Go, a client has one live-metrics sink: calling this again attaches the new monitor
    /// in place of the previous one. The client holds the monitor weakly; keep a reference for
    /// as long as you want updates. Call `start()` to begin periodic sampling.
    public func monitor(
        interval: Duration = Monitor.defaultInterval,
        sampler: MetricsSampler = TimestampSampler()
    ) -> Monitor {
        let monitor = Monitor(sampler: sampler, interval: interval)
        metricsSink.attach(monitor)
        return monitor
    }
}
