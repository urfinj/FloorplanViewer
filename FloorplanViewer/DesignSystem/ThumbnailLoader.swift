import ImageIO
import UIKit

/// Off-main, downsampled disk-image loader with a small in-memory cache. ImageIO produces the
/// thumbnail at the target pixel size directly, so a list row never decodes a full preview image.
/// The `@concurrent` decode returns a `sending` image, letting the non-`Sendable` `UIImage` cross
/// back to the main actor as a fresh, disconnected value.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 32
    }

    func thumbnail(at url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let maxPixel = max(1, side * scale)
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = await Self.downsample(url: url, maxPixel: maxPixel, scale: scale) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    @concurrent
    nonisolated static func downsample(url: URL, maxPixel: CGFloat, scale: CGFloat) async -> sending UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
