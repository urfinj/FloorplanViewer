import SwiftUI

/// Renders marker pins above the scroll view at constant screen size, positions derived from
/// `ViewportState`. Hit-testing is off — touch interaction flows through the UIKit tap
/// recognizer and the pure resolver — but each pin remains a VoiceOver element whose activate
/// action toggles selection (deletion then lives in the inspector sheet), so assistive-tech
/// users are not locked out of an interaction they cannot aim by tapping.
struct MarkerOverlayView: View {
    let markers: [Marker]
    let selectedID: String?
    let viewport: ViewportState
    let imageSize: CGSize
    let onActivate: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Culling keeps one full extra viewport alive on every side (not a thin strip): during an
    /// animated zoom step a pin's start or end position can sit well outside the visible bounds,
    /// and culling it there would make it pop in/out instead of gliding with the canvas.
    private var cullMargin: CGFloat {
        max(viewport.boundsSize.width, viewport.boundsSize.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // `EnumeratedSequence` gains RandomAccessCollection only on iOS 26; materialize for
            // the app's iOS 17 deployment floor.
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                if let point = screenPoint(for: marker) {
                    pin(isSelected: marker.id == selectedID)
                        .position(point)
                        .accessibilityLabel(accessibilityText(index: index, isSelected: marker.id == selectedID))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            onActivate(marker.id)
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func accessibilityText(index: Int, isSelected: Bool) -> String {
        var text = "Marker \(index + 1) of \(markers.count)"
        if isSelected {
            text += ", selected"
        }
        return text
    }

    private func screenPoint(for marker: Marker) -> CGPoint? {
        let image = ViewportMath.normalizedToImage(
            x: marker.normalizedX, y: marker.normalizedY, imageSize: imageSize
        )
        let screen = ViewportMath.toScreen(
            imagePoint: image, zoomScale: viewport.zoomScale, contentOffset: viewport.contentOffset
        )
        guard screen.x > -cullMargin, screen.x < viewport.boundsSize.width + cullMargin,
              screen.y > -cullMargin, screen.y < viewport.boundsSize.height + cullMargin
        else { return nil }
        return screen
    }

    private func pin(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                // The app's one signature detail: a blueprint-blue ring, constant screen size,
                // anchor glued to the plan point.
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 40, height: 40)
            }
            Image(systemName: "mappin.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : Color.orange)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .scaleEffect(isSelected ? 1.15 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: isSelected)
    }
}
