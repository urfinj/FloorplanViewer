import UIKit

/// Loads tile images for the renderer: NSCache-backed, file-lazy (`UIImage(contentsOfFile:)` —
/// no full-floorplan bitmap ever exists), `nil` for missing tiles (the draw path skips them).
///
/// This is the project's one deliberately `nonisolated` UIKit-adjacent type (plan 00 §9.6):
/// `CATiledLayer` invokes `draw(_:)` concurrently on background threads, so the provider must be
/// callable off the main actor.
///
/// @unchecked Sendable: all stored state is `let`; `NSCache` is documented thread-safe
/// ("you can add, remove, and query items in the cache from different threads without having
/// to lock the cache yourself") but is not annotated `Sendable` in the SDK; file reads are
/// stateless.
final nonisolated class TileProvider: @unchecked Sendable {
    private let tilesDirectoryURL: URL
    private let pyramid: TilePyramid
    private let cache = NSCache<NSString, UIImage>()

    init(
        tilesDirectoryURL: URL,
        pyramid: TilePyramid,
        cacheLimit: Int = 120,
        cacheCostLimit: Int = 48 * 1_024 * 1_024
    ) {
        self.tilesDirectoryURL = tilesDirectoryURL
        self.pyramid = pyramid
        cache.countLimit = cacheLimit // ~a few screenfuls of tiles
        cache.totalCostLimit = cacheCostLimit
    }

    func tileImage(level: Int, col: Int, row: Int) -> UIImage? {
        let key = "\(level)/\(col)_\(row)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let url = tilesDirectoryURL.appending(path: pyramid.tileRelativePath(level: level, col: col, row: row))
        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        // Predecode once, here on the background draw thread (`UIImage(contentsOfFile:)` is lazy —
        // without this, JPEG decode can re-run inside every draw that hits this tile).
        let prepared = image.preparingForDisplay() ?? image
        let cost = prepared.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(prepared, forKey: key, cost: cost)
        return prepared
    }
}
