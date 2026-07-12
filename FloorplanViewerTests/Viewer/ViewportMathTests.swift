import CoreGraphics
import Foundation
import Testing
@testable import FloorplanViewer

struct ViewportMathTests {
    @Test(arguments: [
        (zoom: 0.118, offset: CGPoint(x: -40, y: -180)), // fitted + centering insets (negative offset)
        (zoom: 1.0, offset: CGPoint(x: 800, y: 400)),
        (zoom: 2.5, offset: CGPoint(x: 5000, y: 3000))
    ])
    func screenImageRoundTrip(entry: (zoom: CGFloat, offset: CGPoint)) {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 825, y: 1276), CGPoint(x: 3300, y: 2552)]
        for point in points {
            let screen = ViewportMath.toScreen(imagePoint: point, zoomScale: entry.zoom, contentOffset: entry.offset)
            let back = ViewportMath.toImage(screenPoint: screen, zoomScale: entry.zoom, contentOffset: entry.offset)
            #expect(abs(back.x - point.x) < 1e-9)
            #expect(abs(back.y - point.y) < 1e-9)
        }
    }

    @Test func normalizedConversionAndBounds() {
        let size = CGSize(width: 3300, height: 2552)
        let point = ViewportMath.normalizedToImage(x: 0.25, y: 0.75, imageSize: size)
        #expect(point == CGPoint(x: 825, y: 1914))
        #expect(ViewportMath.isWithinImage(point, imageSize: size))
        #expect(!ViewportMath.isWithinImage(CGPoint(x: -1, y: 10), imageSize: size))
        #expect(!ViewportMath.isWithinImage(CGPoint(x: 10, y: 2553), imageSize: size))
    }

    @Test func normalizedPointFromScreenCenter() throws {
        // Unzoomed 1000×800 image fully visible: the viewport center maps to (0.5, 0.5).
        let normalized = try #require(ViewportMath.normalizedPoint(
            screenPoint: CGPoint(x: 500, y: 400),
            zoomScale: 1,
            contentOffset: .zero,
            imageSize: CGSize(width: 1000, height: 800)
        ))
        #expect(normalized.x == 0.5)
        #expect(normalized.y == 0.5)
    }

    @Test func normalizedPointRoundTripsUnderZoomAndOffset() throws {
        let imageSize = CGSize(width: 3300, height: 2552)
        let offset = CGPoint(x: 512, y: 384)
        let imagePoint = CGPoint(x: 825, y: 1914) // normalized (0.25, 0.75)
        let screen = ViewportMath.toScreen(imagePoint: imagePoint, zoomScale: 2.5, contentOffset: offset)
        let normalized = try #require(ViewportMath.normalizedPoint(
            screenPoint: screen, zoomScale: 2.5, contentOffset: offset, imageSize: imageSize
        ))
        #expect(abs(normalized.x - 0.25) < 1e-9)
        #expect(abs(normalized.y - 0.75) < 1e-9)
    }

    @Test func normalizedPointRejectsMarginsAndDegenerateInput() {
        // Letterboxed margin around a fitted plan: (10 − 40) / 0.1 = −300 → off-image → nil.
        let inMargin = ViewportMath.normalizedPoint(
            screenPoint: CGPoint(x: 10, y: 10),
            zoomScale: 0.1,
            contentOffset: CGPoint(x: -40, y: -180),
            imageSize: CGSize(width: 1000, height: 800)
        )
        #expect(inMargin == nil)
        let degenerate = ViewportMath.normalizedPoint(
            screenPoint: .zero, zoomScale: 0, contentOffset: .zero, imageSize: CGSize(width: 100, height: 100)
        )
        #expect(degenerate == nil)
    }

    @Test func zoomLimitFormulas() {
        // iPhone 15 Pro portrait content area over sample-1.
        let fit = ViewportMath.fitScale(
            imageSize: CGSize(width: 3300, height: 2552),
            boundsSize: CGSize(width: 393, height: 759)
        )
        #expect(abs(fit - 393.0 / 3300.0) < 1e-9) // width-limited
        #expect(ViewportMath.maxScale(fit: fit) == 1) // fit·8 < 1 → clamp to 1:1
        // iPad landscape: fit·8 exceeds 1 → headroom wins.
        let iPadFit = ViewportMath.fitScale(
            imageSize: CGSize(width: 3300, height: 2552),
            boundsSize: CGSize(width: 1180, height: 820)
        )
        #expect(ViewportMath.maxScale(fit: iPadFit) == iPadFit * 8)
    }
}
