import CoreGraphics
import Observation

/// Live scroll-view geometry, pushed from the UIKit coordinator on every scroll/zoom/layout and
/// consumed by the SwiftUI marker overlay (pin placement) and the zoom buttons (limit-disable).
@MainActor
@Observable
final class ViewportState {
    private(set) var zoomScale: CGFloat = 1
    private(set) var contentOffset: CGPoint = .zero
    private(set) var boundsSize: CGSize = .zero
    private(set) var minimumZoomScale: CGFloat = 1
    private(set) var maximumZoomScale: CGFloat = 1

    func update(zoomScale: CGFloat, contentOffset: CGPoint, boundsSize: CGSize) {
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
        self.boundsSize = boundsSize
    }

    /// Layout-time zoom limits. Guarded: `layoutSubviews` fires per scroll frame and the values
    /// rarely change — skipping identical writes avoids spurious observation invalidations.
    func updateLimits(minimum: CGFloat, maximum: CGFloat) {
        guard minimum != minimumZoomScale || maximum != maximumZoomScale else { return }
        minimumZoomScale = minimum
        maximumZoomScale = maximum
    }

    /// Small epsilon so a fitted / maxed-out view reports its bound as reached (buttons disable).
    var canZoomIn: Bool {
        zoomScale < maximumZoomScale - 0.001
    }

    var canZoomOut: Bool {
        zoomScale > minimumZoomScale + 0.001
    }
}
