import CoreGraphics
import Observation

/// Live scroll-view geometry, pushed from the UIKit coordinator on every scroll/zoom/layout and
/// consumed by the SwiftUI marker overlay to place pins in screen space.
@MainActor
@Observable
final class ViewportState {
    private(set) var zoomScale: CGFloat = 1
    private(set) var contentOffset: CGPoint = .zero
    private(set) var boundsSize: CGSize = .zero

    func update(zoomScale: CGFloat, contentOffset: CGPoint, boundsSize: CGSize) {
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
        self.boundsSize = boundsSize
    }
}
