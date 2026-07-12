import SwiftUI

/// A restrained skeleton pulse. Reduce Motion keeps the placeholder static while preserving the
/// same hierarchy and contrast.
struct LoadingPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.62)
        } else {
            content.phaseAnimator([false, true]) { view, highlighted in
                view.opacity(highlighted ? 0.82 : 0.42)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }
}
