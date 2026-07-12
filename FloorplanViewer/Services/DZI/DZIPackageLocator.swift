import Foundation

/// The two roots the viewer/validator need from an extracted package: the `.dzi` descriptor file
/// and the directory that holds the numbered tile-level folders. Produced by ``DZIPackageLocator``;
/// container-relative resolution and readiness validation happen in Phase 4.
nonisolated struct DZIPackageLayout: Equatable, Sendable {
    /// Absolute URL of the located `.dzi` descriptor.
    let descriptorURL: URL
    /// Absolute URL of the directory containing the integer-named tile-level folders.
    let tilesDirectoryURL: URL
}

/// Errors surfaced by ``DZIPackageLocator/locate(in:)``.
nonisolated enum DZILocatorError: Error, Equatable {
    /// No `*.dzi` file was found within the bounded-depth scan.
    case descriptorNotFound
    /// A descriptor was found but no tile directory could be resolved for it.
    case tilesMissing
}

/// Locates the DZI descriptor and tile directory inside an extracted package **without hardcoding
/// folder names** — the sample archives ship `tileset/floorplan.dzi` + `tiles/`, not the canonical
/// `<name>_files/`. The recursive descriptor scan makes the locator indifferent to any wrapper
/// nesting the archive introduces (`./`, `tileset/`, …).
///
/// `nonisolated` and dependency-free (only `FileManager`): callable from `@concurrent` extraction.
nonisolated enum DZIPackageLocator {
    /// Maximum directory depth searched for a descriptor (root = 0). Generous for real archives,
    /// which nest one or two levels; bounds the scan against pathological trees.
    private static let maxScanDepth = 5

    /// Locates the descriptor and tile directory under `root`.
    ///
    /// 1. Recursively scan (bounded depth) for `*.dzi`; pick deterministically — shallowest, then
    ///    lexicographic by path. None → ``DZILocatorError/descriptorNotFound``.
    /// 2. Resolve the tile directory among the descriptor's siblings: prefer the canonical
    ///    `<basename>_files/`; otherwise a sibling directory containing integer-named subdirs
    ///    (most such children wins, then lexicographic). None → ``DZILocatorError/tilesMissing``.
    static func locate(in root: URL) throws -> DZIPackageLayout {
        let fileManager = FileManager.default
        var descriptors: [(url: URL, depth: Int)] = []
        collectDescriptors(in: root, depth: 0, into: &descriptors, fileManager: fileManager)

        guard let descriptorURL = pickDescriptor(descriptors) else {
            throw DZILocatorError.descriptorNotFound
        }
        guard let tilesDirectoryURL = resolveTilesDirectory(for: descriptorURL, fileManager: fileManager) else {
            throw DZILocatorError.tilesMissing
        }
        return DZIPackageLayout(descriptorURL: descriptorURL, tilesDirectoryURL: tilesDirectoryURL)
    }

    // MARK: - Descriptor discovery

    private static func collectDescriptors(
        in directory: URL,
        depth: Int,
        into results: inout [(url: URL, depth: Int)],
        fileManager: FileManager
    ) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            if isDirectory(entry) {
                if depth < maxScanDepth {
                    collectDescriptors(in: entry, depth: depth + 1, into: &results, fileManager: fileManager)
                }
            } else if entry.pathExtension.lowercased() == "dzi" {
                results.append((entry.standardizedFileURL, depth))
            }
        }
    }

    /// Deterministic pick: shallowest depth wins; ties broken by lexicographic path order.
    private static func pickDescriptor(_ descriptors: [(url: URL, depth: Int)]) -> URL? {
        descriptors.min { lhs, rhs in
            lhs.depth != rhs.depth ? lhs.depth < rhs.depth : lhs.url.path < rhs.url.path
        }?.url
    }

    // MARK: - Tile directory resolution

    private static func resolveTilesDirectory(for descriptorURL: URL, fileManager: FileManager) -> URL? {
        let parent = descriptorURL.deletingLastPathComponent()
        let basename = descriptorURL.deletingPathExtension().lastPathComponent

        // Preference 1: the canonical `<basename>_files/` sibling.
        let canonical = parent.appendingPathComponent("\(basename)_files", isDirectory: true)
        if isDirectory(canonical) {
            return canonical
        }

        // Preference 2: a sibling directory whose immediate children include integer-named subdirs.
        let siblings = (try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = siblings
            .filter { isDirectory($0) }
            .map { (url: $0, levelCount: integerNamedChildCount(of: $0, fileManager: fileManager)) }
            .filter { $0.levelCount > 0 }

        return candidates.min { lhs, rhs in
            lhs.levelCount != rhs.levelCount ? lhs.levelCount > rhs.levelCount : lhs.url.path < rhs.url.path
        }?.url
    }

    private static func integerNamedChildCount(of directory: URL, fileManager: FileManager) -> Int {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { isDirectory($0) && isIntegerName($0.lastPathComponent) }.count
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// True when `name` is a non-empty run of ASCII digits (`0`, `4`, `10`) — the DZI tile-level
    /// folder convention. Rejects `-1`, `+1`, `1e3`, `1.0`, and empty names.
    private static func isIntegerName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}
