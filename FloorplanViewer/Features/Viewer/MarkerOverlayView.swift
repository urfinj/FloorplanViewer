import SwiftUI

/// Renders marker pins above the scroll view at constant screen size, positions derived from
/// `ViewportState`. Hit-testing is off — all interaction flows through the UIKit tap recognizer
/// and the pure resolver; markers stay discoverable to VoiceOver as labeled elements.
struct MarkerOverlayView: View {
    let markers: [Marker]
    let selectedID: String?
    let viewport: ViewportState
    let imageSize: CGSize

    private static let cullMargin: CGFloat = 50

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                if let point = screenPoint(for: marker) {
                    pin(isSelected: marker.id == selectedID)
                        .position(point)
                        .accessibilityLabel("Marker \(index + 1) of \(markers.count)")
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func screenPoint(for marker: Marker) -> CGPoint? {
        let image = ViewportMath.normalizedToImage(
            x: marker.normalizedX, y: marker.normalizedY, imageSize: imageSize
        )
        let screen = ViewportMath.toScreen(
            imagePoint: image, zoomScale: viewport.zoomScale, contentOffset: viewport.contentOffset
        )
        guard screen.x > -Self.cullMargin, screen.x < viewport.boundsSize.width + Self.cullMargin,
              screen.y > -Self.cullMargin, screen.y < viewport.boundsSize.height + Self.cullMargin
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
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}
