import Foundation

/// Resolves the on-disk container shared by the database and package files, so the store path and
/// `PackageStorage.root` derive from one place.
nonisolated enum AppContainer {
    /// `Application Support/FloorplanViewer/` (created if absent).
    static func directory() throws -> URL {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "FloorplanViewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The GRDB store file URL (backed up — markers are user data).
    static func databaseURL() throws -> URL {
        try directory().appending(path: "FloorplanViewer.sqlite", directoryHint: .notDirectory)
    }

    /// The packages root (`archives/`, `extracted/`, `staging/` live under here). Excluded from
    /// backup: the bytes are re-downloadable, but Caches could be purged and break the offline promise.
    static func packagesURL() throws -> URL {
        var url = try directory().appending(path: "Packages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Destructive reset: removes the whole container (db + packages). The next launch recreates it.
    static func reset() throws {
        let dir = try directory()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
