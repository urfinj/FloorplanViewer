import CoreGraphics

/// Imperative bridge from SwiftUI controls to the `UIScrollView` zoom API. The representable's
/// coordinator installs these closures in `makeUIView`; controls invoke them. Discrete zoom is a
/// command, not derived state, so it lives here rather than on the declarative update path.
@MainActor
final class ViewportController {
    var zoomBy: ((CGFloat) -> Void)?
    var zoomToFit: (() -> Void)?

    /// One press = one 1.6× step — a noticeable move that still needs a few taps across the range,
    /// matching the double-tap feel.
    static let step: CGFloat = 1.6

    func zoomIn() {
        zoomBy?(Self.step)
    }

    func zoomOut() {
        zoomBy?(1 / Self.step)
    }

    func fit() {
        zoomToFit?()
    }
}
