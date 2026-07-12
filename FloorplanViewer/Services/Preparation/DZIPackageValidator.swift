import Foundation

/// Production validation: locate → parse → verify the tile pyramid — all **in staging, before
/// promotion**. Probes both the top-left and the computed bottom-right full-resolution tiles, so
/// a truncated copy can never be promoted; requires contiguous levels `0…M`.
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

        // Probe the two full-resolution corners.
        let (cols, rows) = pyramid.grid(atLevel: maxLevel)
        let probes = [
            pyramid.tileRelativePath(level: maxLevel, col: 0, row: 0),
            pyramid.tileRelativePath(level: maxLevel, col: cols - 1, row: rows - 1)
        ]
        for probe in probes {
            let url = layout.tilesDirectoryURL.appending(path: probe)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PreparationError(reason: .tilesMissing)
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
}
