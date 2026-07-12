import CoreGraphics
import Foundation

/// What a floorplan tap should do.
nonisolated enum MarkerTapAction: Equatable, Sendable {
    case place(normalizedX: Double, normalizedY: Double)
    case select(String)
    case deselect
    case none
}

/// Pure tap resolution in image space (locked interaction table):
/// hit a marker → select (or deselect if it was selected); miss with a selection → deselect
/// (guards accidental placement); miss with no selection → place when inside the image.
/// Hit radius is 22 screen points, so it scales as `22 / zoomScale` in image space; the nearest
/// marker within the radius wins.
nonisolated enum MarkerTapResolver {
    static func resolve(
        tapImagePoint tap: CGPoint,
        markers: [Marker],
        selectedID: String?,
        zoomScale: CGFloat,
        imageSize: CGSize
    ) -> MarkerTapAction {
        guard imageSize.width > 0, imageSize.height > 0, zoomScale > 0 else { return .none }
        let hitRadius = 22.0 / zoomScale

        let nearestHit = markers
            .map { marker -> (marker: Marker, distance: CGFloat) in
                let point = ViewportMath.normalizedToImage(
                    x: marker.normalizedX, y: marker.normalizedY, imageSize: imageSize
                )
                return (marker, hypot(point.x - tap.x, point.y - tap.y))
            }
            .filter { $0.distance <= hitRadius }
            .min { $0.distance < $1.distance }

        if let hit = nearestHit {
            return hit.marker.id == selectedID ? .deselect : .select(hit.marker.id)
        }
        if selectedID != nil {
            return .deselect
        }
        guard ViewportMath.isWithinImage(tap, imageSize: imageSize) else { return .none }
        return .place(
            normalizedX: Double(tap.x / imageSize.width),
            normalizedY: Double(tap.y / imageSize.height)
        )
    }
}
