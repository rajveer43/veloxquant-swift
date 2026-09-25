#if os(macOS)

import Foundation
import VeloxQuantCore

/// A model found in the local Hugging Face cache. Field set follows Go's `models.LocalModel`
/// (`veloxquant-go/models/local.go`: name, path, size, last-modified) with Kotlin's
/// `repoID` naming.
public struct LocalModel: Sendable, Equatable, Identifiable {
    /// Same as `repoID`.
    public var id: String { repoID }
    /// Hugging Face repo id, e.g. `mlx-community/Qwen3-8B-4bit`.
    public let repoID: String
    /// The `models--...` cache directory.
    public let path: URL
    /// Total size of regular files under `path`, in bytes.
    public let sizeBytes: UInt64
    /// Most recent modification time of anything under `path`, if any could be read.
    public let lastModified: Date?

    /// Creates a record.
    public init(repoID: String, path: URL, sizeBytes: UInt64, lastModified: Date?) {
        self.repoID = repoID
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
    }
}

// `listMethods`/`listLocalModels` live in `VeloxQuantRuntime`, not on `VeloxQuantClient` in
// `VeloxQuantCore`: one is a CLI shell-out and the other a filesystem scan, with no HTTP route
// for either — the placement Kotlin had to correct mid-build (plan §3.4), made right first time.
extension VeloxQuantProcess {
    /// Lists compression methods via `methods --json` (plan §3.4). Kotlin's `listMethods()`.
    public static func listMethods(
        pythonEnvironment: PythonEnvironment,
        servableOnly: Bool = false,
        runner: ProcessRunning = FoundationProcessRunner()
    ) async throws -> [CompressionMethod] {
        try await VeloxQuantCLI(pythonEnvironment: pythonEnvironment, runner: runner)
            .methods(servableOnly: servableOnly)
            .methods
    }

    /// The Hugging Face hub cache directory: `$HF_HOME/hub` if `HF_HOME` is set, otherwise
    /// `~/.cache/huggingface/hub` — Go's `models.LocalCacheDir`, Kotlin's `defaultHfCacheDir`.
    public static func defaultModelCacheDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Scans the local Hugging Face cache for `models--<org>--<name>` directories. Dependency-
    /// free (no Python), like Go's `ScanLocal`: a missing or unreadable cache yields `[]`, not
    /// an error. Results are sorted by `repoID` (Kotlin's ordering).
    ///
    /// Size counts regular files only. The HF cache stores bytes once in `blobs/` and links to
    /// them from `snapshots/`; symlinks are skipped so shared blobs are not double-counted (Go
    /// adds each symlink's own few-byte `lstat` size; Kotlin follows them and double-counts).
    public static func listLocalModels(cacheDirectory: URL? = nil) -> [LocalModel] {
        let directory = cacheDirectory ?? defaultModelCacheDirectory()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return entries.compactMap { entry -> LocalModel? in
            let name = entry.lastPathComponent
            guard name.hasPrefix("models--"),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }

            let (size, modified) = directoryTotals(entry)
            let repoID = String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            return LocalModel(repoID: repoID, path: entry, sizeBytes: size, lastModified: modified)
        }
        .sorted { $0.repoID < $1.repoID }
    }

    private static func directoryTotals(_ directory: URL) -> (UInt64, Date?) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var total: UInt64 = 0
        var latest = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return (0, latest)
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true, let size = values.fileSize {
                total += UInt64(size)
            }
            if let modified = values.contentModificationDate, modified > (latest ?? .distantPast) {
                latest = modified
            }
        }
        return (total, latest)
    }
}

#else

#error("VeloxQuantRuntime requires macOS — process management and CLI shell-outs are not available on this platform.")

#endif
