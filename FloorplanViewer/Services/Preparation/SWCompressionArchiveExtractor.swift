import Foundation
import os
import SWCompression

/// Production extraction: SWCompression gunzip + tar walk into `directory`.
///
/// Safety posture:
/// - path traversal guard: absolute paths, `..` components, and anything resolving outside the
///   destination are skipped (never written);
/// - only regular files and directories are materialized — symlinks/hardlinks/devices are skipped;
/// - generous documented bounds on entry count and expanded bytes defend against malformed input.
///
/// The whole archive is decoded in memory — fine for these ~600 KB packages; streaming decode is a
/// documented future improvement.
nonisolated struct SWCompressionArchiveExtractor: ArchiveExtracting {
    var maxEntries = 10_000
    var maxExpandedBytes = 1 << 30 // 1 GB

    @concurrent
    func extract(archiveURL: URL, into directory: URL) async throws {
        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: archiveURL)
        } catch {
            throw PreparationError(reason: .extractionFailed)
        }

        let tarData: Data
        let entries: [TarEntry]
        do {
            tarData = try GzipArchive.unarchive(archive: archiveData)
            // Reject oversized input before `TarContainer.open` materializes it a second time —
            // the per-entry bound below only runs after everything is already in memory.
            guard tarData.count <= maxExpandedBytes else {
                Log.prep.error("Archive rejected: expanded gzip size exceeds bound")
                throw PreparationError(reason: .corruptArchive)
            }
            entries = try TarContainer.open(container: tarData)
        } catch {
            throw PreparationError(reason: .corruptArchive)
        }
        guard entries.count <= maxEntries else {
            Log.prep.error("Archive rejected: \(entries.count) entries exceeds bound")
            throw PreparationError(reason: .corruptArchive)
        }

        let root = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var expandedBytes = 0
        for entry in entries {
            try Task.checkCancellation()
            guard let destination = Self.safeDestination(for: entry.info.name, under: root) else {
                continue // hostile or degenerate path — skipped, never written
            }
            switch entry.info.type {
            case .directory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case .regular:
                let data = entry.data ?? Data()
                expandedBytes += data.count
                guard expandedBytes <= maxExpandedBytes else {
                    Log.prep.error("Archive rejected: expanded size exceeds bound")
                    throw PreparationError(reason: .corruptArchive)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try data.write(to: destination, options: .atomic)
                } catch {
                    throw PreparationError.classify(error)
                }
            default:
                Log.prep.notice("Skipping non-regular tar entry: \(entry.info.name, privacy: .public)")
            }
        }
    }

    /// Resolves a tar entry name to a destination inside `root`, or `nil` for anything unsafe:
    /// absolute paths, `..` traversal, or a resolved path escaping the root. The real packages
    /// prefix entries with `./`, so bare `.` components are dropped (a `./` root entry resolves to
    /// nothing and is skipped).
    static func safeDestination(for name: String, under root: URL) -> URL? {
        guard !name.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in name.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": return nil
            default: components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        let destination = root.appending(path: components.joined(separator: "/")).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }
        return destination
    }
}
