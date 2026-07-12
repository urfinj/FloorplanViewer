import CoreGraphics
import Foundation

/// Pure tile-pyramid geometry for a DZI package. Every formula is locked in plan `00 §10`.
///
/// **Locked model:** the highest folder level (`maxFolderLevel`, discovered from disk) is
/// full resolution — true for canonical DZI and for the samples' vips `--depth onetile` exports.
/// Level `L ∈ 0…M` has downscale `2^(M−L)`, so level `M` is 1:1 with the source image.
///
/// `nonisolated`, `Sendable`, dependency-free math: safe to use from the CATiledLayer background
/// draw path and from `@concurrent` validation.
nonisolated struct TilePyramid: Sendable {
    /// The validated descriptor this pyramid derives from.
    let descriptor: DZIDescriptor
    /// `M` — the highest tile-level folder index, i.e. the full-resolution level.
    let maxFolderLevel: Int

    /// - Throws: ``TilePyramidError/negativeMaxFolderLevel(_:)`` when `maxFolderLevel < 0`.
    init(descriptor: DZIDescriptor, maxFolderLevel: Int) throws {
        guard maxFolderLevel >= 0 else {
            throw TilePyramidError.negativeMaxFolderLevel(maxFolderLevel)
        }
        self.descriptor = descriptor
        self.maxFolderLevel = maxFolderLevel
    }

    // MARK: - Level geometry

    /// Number of levels, `M + 1` (levels `0…M`).
    var levelCount: Int {
        maxFolderLevel + 1
    }

    /// Full-resolution image size in pixels.
    var fullSize: CGSize {
        CGSize(width: descriptor.width, height: descriptor.height)
    }

    /// Downscale factor at `level`: `2^(M − L)`. Level is clamped to `0…M`.
    func downscale(atLevel level: Int) -> Int {
        1 << (maxFolderLevel - clampLevel(level))
    }

    /// Pixel size of `level`: `ceil(W/d) × ceil(H/d)`. Level is clamped to `0…M`.
    func size(atLevel level: Int) -> CGSize {
        let scale = downscale(atLevel: level)
        return CGSize(width: ceilDiv(descriptor.width, scale), height: ceilDiv(descriptor.height, scale))
    }

    /// Tile grid at `level`: `ceil(wL/T) × ceil(hL/T)`. Level is clamped to `0…M`.
    func grid(atLevel level: Int) -> (cols: Int, rows: Int) {
        let levelSize = size(atLevel: level)
        return (
            cols: ceilDiv(Int(levelSize.width), descriptor.tileSize),
            rows: ceilDiv(Int(levelSize.height), descriptor.tileSize)
        )
    }

    // MARK: - Tiles

    /// Package-relative path of a tile: `"<L>/<col>_<row>.<format>"`. Level is clamped to `0…M`.
    func tileRelativePath(level: Int, col: Int, row: Int) -> String {
        "\(clampLevel(level))/\(col)_\(row).\(descriptor.format)"
    }

    /// Tile frame in **level space** (pixels at `level`): overlap-aware and clipped to the level
    /// bounds. `x = col·T − (col>0 ? O : 0)`, `width = T + leftOverlap + rightOverlap` (mirror for
    /// y/height), then clipped to `[0, wL] × [0, hL]`.
    func tileFrameInLevelSpace(level: Int, col: Int, row: Int) -> CGRect {
        let bounds = levelTileBounds(level: level, col: col, row: row)
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }

    /// Tile frame in **image space** (full-resolution pixels): the level-space frame × downscale.
    func tileFrameInImageSpace(level: Int, col: Int, row: Int) -> CGRect {
        let scale = downscale(atLevel: level)
        let bounds = levelTileBounds(level: level, col: col, row: row)
        return CGRect(
            x: bounds.x * scale,
            y: bounds.y * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    // MARK: - Level-of-detail selection

    /// Maps a render LOD scale to a folder level: `clamp(M + round(log2(scale)), 0, M)`.
    /// `scale <= 0` is treated as the coarsest level.
    func folderLevel(forLODScale scale: CGFloat) -> Int {
        guard scale > 0 else { return 0 }
        let level = maxFolderLevel + Int(log2(Double(scale)).rounded())
        return min(max(level, 0), maxFolderLevel)
    }

    /// Half-open column/row ranges of the tiles whose base cells intersect `imageRect` (given in
    /// full-resolution image space) at `level`. Ranges are clamped to the level grid; a disjoint or
    /// degenerate rect yields empty ranges. Overlap widens drawn frames but not tile ownership, so
    /// indexing uses base `T`-sized cells.
    func tileIndices(intersecting imageRect: CGRect, atLevel level: Int) -> (cols: Range<Int>, rows: Range<Int>) {
        let clampedLevel = clampLevel(level)
        let (cols, rows) = grid(atLevel: clampedLevel)
        guard imageRect.width > 0, imageRect.height > 0 else {
            return (0 ..< 0, 0 ..< 0)
        }
        let cell = Double(downscale(atLevel: clampedLevel) * descriptor.tileSize)
        let colStart = clampIndex((Double(imageRect.minX) / cell).rounded(.down), upperBound: cols)
        let colEnd = clampIndex((Double(imageRect.maxX) / cell).rounded(.up), upperBound: cols)
        let rowStart = clampIndex((Double(imageRect.minY) / cell).rounded(.down), upperBound: rows)
        let rowEnd = clampIndex((Double(imageRect.maxY) / cell).rounded(.up), upperBound: rows)

        guard colStart < colEnd, rowStart < rowEnd else {
            return (0 ..< 0, 0 ..< 0)
        }
        return (colStart ..< colEnd, rowStart ..< rowEnd)
    }

    // MARK: - Disk discovery

    /// Highest integer-named subdirectory of `tilesDirectoryURL` — the full-resolution level `M`.
    ///
    /// - Throws: ``TilePyramidError/noLevelDirectories`` when no integer-named subdirectory exists.
    static func discoverMaxFolderLevel(tilesDirectoryURL: URL) throws -> Int {
        guard let maxLevel = integerLevelDirectories(in: tilesDirectoryURL).max() else {
            throw TilePyramidError.noLevelDirectories
        }
        return maxLevel
    }

    /// The set of integer-named tile-level folders present on disk. The validator checks this for
    /// contiguity `0…M`; a gap (e.g. `{0, 2}`) fails validation rather than blanking at render time.
    static func availableLevels(tilesDirectoryURL: URL) -> Set<Int> {
        Set(integerLevelDirectories(in: tilesDirectoryURL))
    }

    // MARK: - Private

    private func clampLevel(_ level: Int) -> Int {
        min(max(level, 0), maxFolderLevel)
    }

    private func ceilDiv(_ numerator: Int, _ denominator: Int) -> Int {
        (numerator + denominator - 1) / denominator
    }

    private func clampIndex(_ value: Double, upperBound: Int) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(min(max(value, 0), Double(upperBound)))
    }

    private func levelTileBounds(level: Int, col: Int, row: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let clampedLevel = clampLevel(level)
        let (cols, rows) = grid(atLevel: clampedLevel)
        let levelSize = size(atLevel: clampedLevel)
        let tile = descriptor.tileSize
        let overlap = descriptor.overlap

        let leftOverlap = col > 0 ? overlap : 0
        let rightOverlap = col < cols - 1 ? overlap : 0
        let topOverlap = row > 0 ? overlap : 0
        let bottomOverlap = row < rows - 1 ? overlap : 0

        let x = col * tile - leftOverlap
        let y = row * tile - topOverlap
        let clampedX = max(0, x)
        let clampedY = max(0, y)
        let clampedRight = min(x + tile + leftOverlap + rightOverlap, Int(levelSize.width))
        let clampedBottom = min(y + tile + topOverlap + bottomOverlap, Int(levelSize.height))

        return (
            x: clampedX,
            y: clampedY,
            width: max(0, clampedRight - clampedX),
            height: max(0, clampedBottom - clampedY)
        )
    }

    private static func integerLevelDirectories(in url: URL) -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDirectory else { return nil }
            return levelIndex(fromDirectoryName: entry.lastPathComponent)
        }
    }

    private static func levelIndex(fromDirectoryName name: String) -> Int? {
        guard !name.isEmpty, name.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(name)
    }
}

/// Errors surfaced by ``TilePyramid``.
nonisolated enum TilePyramidError: Error, Equatable {
    /// `maxFolderLevel` passed to the initializer was negative.
    case negativeMaxFolderLevel(Int)
    /// No integer-named level directory was found under the tiles directory.
    case noLevelDirectories
}
