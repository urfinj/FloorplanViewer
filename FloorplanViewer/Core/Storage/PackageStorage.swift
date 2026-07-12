import Foundation

/// Typed storage failure.
nonisolated enum PackageStorageError: Error, Sendable {
    case invalidRelativePath(String)
}

/// Owns the on-disk package layout under the packages root. All paths persisted in the database
/// are **relative** to `root`; resolution rejects escapes (`..`, absolute inputs). Promotion uses
/// `replaceItemAt` so a valid target survives until its replacement is fully in place.
final nonisolated class PackageStorage: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: - Relative layout

    func archiveRelPath(projectID: String) -> String {
        "archives/\(projectID).tar.gz"
    }

    func extractedRelDir(projectID: String) -> String {
        "extracted/\(projectID)"
    }

    func stagingURL() -> URL {
        root.appending(path: "staging", directoryHint: .isDirectory)
    }

    /// A unique subpath under `staging/` for in-flight work.
    func freshStagingURL(component: String) -> URL {
        stagingURL().appending(path: component, directoryHint: .isDirectory)
    }

    // MARK: - Resolution (escape-rejecting)

    func absoluteURL(for relPath: String) -> URL? {
        let candidate = root.appending(path: relPath).standardizedFileURL
        return isContained(candidate) ? candidate : nil
    }

    func relativePath(for url: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full == base || full.hasPrefix(base + "/") else { return nil }
        return full == base ? "" : String(full.dropFirst(base.count + 1))
    }

    private func isContained(_ url: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: - Queries

    func fileExists(atRelative relPath: String) -> Bool {
        guard let url = absoluteURL(for: relPath) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    func directoryExists(atRelative relPath: String) -> Bool {
        guard let url = absoluteURL(for: relPath) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Mutation

    func wipeStaging() throws {
        let staging = stagingURL()
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
    }

    /// Atomically place a staged file at `relPath`, replacing any existing item.
    func promoteStagedFile(from staged: URL, toRelative relPath: String) throws {
        try promote(from: staged, toRelative: relPath)
    }

    /// Atomically place a staged directory at `relPath`, replacing any existing tree.
    func promoteStagedDirectory(from staged: URL, toRelative relPath: String) throws {
        try promote(from: staged, toRelative: relPath)
    }

    func removeItem(atRelative relPath: String) throws {
        guard let url = absoluteURL(for: relPath) else { throw PackageStorageError.invalidRelativePath(relPath) }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func promote(from staged: URL, toRelative relPath: String) throws {
        guard let dest = absoluteURL(for: relPath) else { throw PackageStorageError.invalidRelativePath(relPath) }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: dest)
        }
    }
}
