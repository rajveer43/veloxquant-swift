#if os(macOS)

import Darwin
import Foundation
import VeloxQuantCore

/// Host memory totals, read via Mach `host_statistics64` — no `vm_stat` shell-out.
public struct HostMemory: Sendable, Equatable {
    /// Total physical memory, in bytes (`hw.memsize`).
    public let totalBytes: UInt64
    /// Available memory, in bytes.
    public let availableBytes: UInt64

    /// Memory in use (`total - available`).
    public var usedBytes: UInt64 { totalBytes - min(availableBytes, totalBytes) }

    /// Creates a snapshot (tests construct these directly).
    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Reads current host memory. Available = (free + inactive) pages × page size, capped at
    /// total, falling back to total if the Mach call fails — the same number Go's
    /// `availableMemoryFromVMStat` derives: it sums `vm_stat`'s "Pages free" + "Pages inactive"
    /// + "Pages speculative", and `vm_stat` prints "Pages free" as `free_count -
    /// speculative_count`, so the sum is exactly `free_count + inactive_count`.
    public static func current() -> HostMemory {
        let total = HardwareDetector.detect().unifiedMemoryBytes
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return HostMemory(totalBytes: total, availableBytes: total)
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize)
        guard available > 0, available <= total else {
            return HostMemory(totalBytes: total, availableBytes: total)
        }
        return HostMemory(totalBytes: total, availableBytes: available)
    }
}

/// Samples host memory (`memoryUsedBytes`/`memoryAvailableBytes`) — Go's default `Client.Monitor`
/// sampler, for macOS.
public struct HostMemorySampler: MetricsSampler {
    /// Creates the sampler.
    public init() {}

    /// Takes one snapshot.
    public func sample() async throws -> Metrics {
        let memory = HostMemory.current()
        return Metrics(memoryUsedBytes: memory.usedBytes, memoryAvailableBytes: memory.availableBytes)
    }
}

/// Samples host memory plus one process's resident set size (`residentMemoryBytes`) via
/// `proc_pidinfo(PROC_PIDTASKINFO)`. Used by `VeloxQuantProcess.monitor(interval:)`.
public struct ProcessMetricsSampler: MetricsSampler {
    /// The process sampled.
    public let processIdentifier: Int32

    /// Creates a sampler for `processIdentifier`.
    public init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    /// Takes one snapshot; `residentMemoryBytes` is `nil` if the process can't be read (e.g. it
    /// exited).
    public func sample() async throws -> Metrics {
        var metrics = try await HostMemorySampler().sample()
        metrics.residentMemoryBytes = Self.residentBytes(of: processIdentifier)
        return metrics
    }

    /// Resident size of `pid` in bytes, or `nil` if unreadable.
    static func residentBytes(of pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard read == size else { return nil }
        return info.pti_resident_size
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
