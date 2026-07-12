import Foundation

/// Production validation: locate → parse → verify the tile pyramid — all **in staging, before
/// promotion**. Requires every expected, non-empty tile across contiguous levels `0…M`, so a
/// sparse or truncated copy can never be promoted and later render as unexplained white holes.
nonisolated struct DZIPackageValidator: PackageValidating {
    @concurrent
    func validate(extractedDir: URL) async throws -> ValidatedPackageLayout {
        let layout: DZIPackageLayout
        do {
            layout = try DZIPackageLocator.locate(in: extractedDir)
        } catch DZILocatorError.descriptorNotFound {
            throw PreparationError(reason: .descriptorNotFound)
        } catch {
            throw PreparationError(reason: .tilesMissing)
        }

        let descriptor: DZIDescriptor
        do {
            let data = try Data(contentsOf: layout.descriptorURL)
            descriptor = try DZIDescriptorParser.parse(data)
        } catch {
            throw PreparationError(reason: .descriptorInvalid)
        }

        let maxLevel: Int
        let pyramid: TilePyramid
        do {
            maxLevel = try TilePyramid.discoverMaxFolderLevel(tilesDirectoryURL: layout.tilesDirectoryURL)
            pyramid = try TilePyramid(descriptor: descriptor, maxFolderLevel: maxLevel)
        } catch {
            throw PreparationError(reason: .tilesMissing)
        }
        // Contiguity: a gap (e.g. levels {0, 2}) fails now rather than blanking at render time.
        let available = TilePyramid.availableLevels(tilesDirectoryURL: layout.tilesDirectoryURL)
        guard available.isSuperset(of: Set(0 ... maxLevel)) else {
            throw PreparationError(reason: .tilesMissing)
        }

        // The sample packages contain fewer than 200 tiles, so a complete metadata scan here is
        // cheap and happens only after extraction. Runtime readiness checks stay corner-probed.
        for level in 0 ... maxLevel {
            let (cols, rows) = pyramid.grid(atLevel: level)
            for row in 0 ..< rows {
                for col in 0 ..< cols {
                    try Task.checkCancellation()
                    let relativePath = pyramid.tileRelativePath(level: level, col: col, row: row)
                    let url = layout.tilesDirectoryURL.appending(path: relativePath)
                    guard Self.isNonEmptyFile(url) else {
                        throw PreparationError(reason: .tilesMissing)
                    }
                }
            }
        }

        // Non-standard `dzi.json` sidecar: debug cross-check only, never load-bearing.
        DZIJSONSidecar.crossCheck(descriptor: descriptor, maxFolderLevel: maxLevel, near: layout.descriptorURL)

        guard let descriptorRel = Self.relativePath(of: layout.descriptorURL, within: extractedDir),
              let tilesRel = Self.relativePath(of: layout.tilesDirectoryURL, within: extractedDir)
        else {
            throw PreparationError(reason: .descriptorNotFound)
        }
        return ValidatedPackageLayout(
            descriptorRelPath: descriptorRel,
            tilesRelDir: tilesRel,
            width: descriptor.width,
            height: descriptor.height,
            tileSize: descriptor.tileSize,
            overlap: descriptor.overlap,
            format: descriptor.format,
            maxFolderLevel: maxLevel
        )
    }

    private static func relativePath(of url: URL, within base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(basePath + "/") else { return nil }
        return String(fullPath.dropFirst(basePath.count + 1))
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
