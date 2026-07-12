import Testing
import UIKit
@testable import FloorplanViewer

struct ThumbnailLoaderTests {
    @Test func downsampleCapsThePixelSize() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 640, height: 480)
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let data = try #require(rendered.jpegData(compressionQuality: 0.8))
        try data.write(to: url)

        let thumb = try #require(await ThumbnailLoader.downsample(url: url, maxPixel: 92, scale: 2))
        let pixelWidth = thumb.size.width * thumb.scale
        let pixelHeight = thumb.size.height * thumb.scale
        #expect(max(pixelWidth, pixelHeight) <= 93) // ImageIO caps the longest side at maxPixel
        #expect(min(pixelWidth, pixelHeight) > 0)
        #expect(thumb.scale == 2)
    }

    @Test func downsampleMissingFileReturnsNil() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "missing-\(UUID().uuidString).jpg")
        let thumb = await ThumbnailLoader.downsample(url: url, maxPixel: 92, scale: 2)
        #expect(thumb == nil)
    }
}
