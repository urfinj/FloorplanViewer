import CoreGraphics

/// Pure screen↔image conversions and zoom-limit formulas (plan 00 §10). The content view's
/// coordinate space is full-resolution image pixels (1 pt ≡ 1 px), so with a UIScrollView:
/// `screen = image·zoom − contentOffset` (centering insets drive the offset negative — the
/// formulas hold unchanged) and `image = (screen + offset) / zoom`.
nonisolated enum ViewportMath {
    static func toScreen(imagePoint: CGPoint, zoomScale: CGFloat, contentOffset: CGPoint) -> CGPoint {
        CGPoint(
            x: imagePoint.x * zoomScale - contentOffset.x,
            y: imagePoint.y * zoomScale - contentOffset.y
        )
    }

    static func toImage(screenPoint: CGPoint, zoomScale: CGFloat, contentOffset: CGPoint) -> CGPoint {
        guard zoomScale > 0 else { return .zero }
        return CGPoint(
            x: (screenPoint.x + contentOffset.x) / zoomScale,
            y: (screenPoint.y + contentOffset.y) / zoomScale
        )
    }

    static func normalizedToImage(x: Double, y: Double, imageSize: CGSize) -> CGPoint {
        CGPoint(x: x * imageSize.width, y: y * imageSize.height)
    }

    static func isWithinImage(_ point: CGPoint, imageSize: CGSize) -> Bool {
        point.x >= 0 && point.x <= imageSize.width && point.y >= 0 && point.y <= imageSize.height
    }

    /// Screen point → normalized `0…1` floorplan coordinates, or `nil` when the point falls
    /// outside the image (letterboxed margins around a fitted plan).
    static func normalizedPoint(
        screenPoint: CGPoint,
        zoomScale: CGFloat,
        contentOffset: CGPoint,
        imageSize: CGSize
    ) -> (x: Double, y: Double)? {
        guard imageSize.width > 0, imageSize.height > 0, zoomScale > 0 else { return nil }
        let image = toImage(screenPoint: screenPoint, zoomScale: zoomScale, contentOffset: contentOffset)
        guard isWithinImage(image, imageSize: imageSize) else { return nil }
        return (Double(image.x / imageSize.width), Double(image.y / imageSize.height))
    }

    /// Aspect-fit zoom for the whole plan.
    static func fitScale(imageSize: CGSize, boundsSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
    }

    /// Inspection headroom: at least 1:1 pixels, up to 8× the fitted view.
    static func maxScale(fit: CGFloat) -> CGFloat {
        max(1, fit * 8)
    }
}
