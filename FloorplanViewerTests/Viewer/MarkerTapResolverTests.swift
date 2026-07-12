import CoreGraphics
import Foundation
import Testing
@testable import FloorplanViewer

/// The locked interaction table + coordinate stability (the assignment's marker-conversion test).
struct MarkerTapResolverTests {
    private let imageSize = CGSize(width: 3300, height: 2552)

    private func marker(_ id: String, _ nx: Double, _ ny: Double) -> Marker {
        Marker(id: id, projectID: "project-1", normalizedX: nx, normalizedY: ny, createdAt: 0)
    }

    @Test func emptyTapPlacesNormalizedMarker() {
        let action = MarkerTapResolver.resolve(
            tapImagePoint: CGPoint(x: 825, y: 1914), markers: [], selectedID: nil,
            zoomScale: 1, imageSize: imageSize
        )
        #expect(action == .place(normalizedX: 0.25, normalizedY: 0.75))
    }

    @Test func tapOnMarkerSelectsAndOnSelectedDeselects() {
        let markers = [marker("a", 0.25, 0.75)]
        let tap = CGPoint(x: 825 + 5, y: 1914 - 5) // within 22pt at zoom 1
        #expect(MarkerTapResolver.resolve(
            tapImagePoint: tap, markers: markers, selectedID: nil, zoomScale: 1, imageSize: imageSize
        ) == .select("a"))
        #expect(MarkerTapResolver.resolve(
            tapImagePoint: tap, markers: markers, selectedID: "a", zoomScale: 1, imageSize: imageSize
        ) == .deselect)
    }

    @Test func nearestMarkerWithinRadiusWins() {
        let markers = [marker("near", 0.25, 0.75), marker("far", 0.253, 0.75)] // ~10px apart
        let action = MarkerTapResolver.resolve(
            tapImagePoint: CGPoint(x: 825 + 2, y: 1914), markers: markers, selectedID: nil,
            zoomScale: 1, imageSize: imageSize
        )
        #expect(action == .select("near"))
    }

    @Test func hitRadiusScalesWithZoom() {
        let markers = [marker("a", 0.25, 0.75)]
        let tap = CGPoint(x: 825 + 15, y: 1914) // 15px away
        // Zoom 1: 15 ≤ 22 → hit.
        #expect(MarkerTapResolver.resolve(
            tapImagePoint: tap, markers: markers, selectedID: nil, zoomScale: 1, imageSize: imageSize
        ) == .select("a"))
        // Zoom 4: radius 5.5px → the same screen-distance tap misses and places instead.
        let zoomed = MarkerTapResolver.resolve(
            tapImagePoint: tap, markers: markers, selectedID: nil, zoomScale: 4, imageSize: imageSize
        )
        guard case .place = zoomed else {
            Issue.record("Expected place at high zoom, got \(zoomed)")
            return
        }
    }

    @Test func missWithSelectionDeselectsInsteadOfPlacing() {
        let markers = [marker("a", 0.25, 0.75)]
        let action = MarkerTapResolver.resolve(
            tapImagePoint: CGPoint(x: 2000, y: 500), markers: markers, selectedID: "a",
            zoomScale: 1, imageSize: imageSize
        )
        #expect(action == .deselect)
    }

    @Test func tapOutsideImageDoesNothingWithoutSelection() {
        let action = MarkerTapResolver.resolve(
            tapImagePoint: CGPoint(x: -50, y: 100), markers: [], selectedID: nil,
            zoomScale: 1, imageSize: imageSize
        )
        #expect(action == .none)
    }

    /// Place → render round trip: the stored normalized point maps back to the same screen point
    /// across zoom/offset/screen-size combinations (marker stays glued through pan/zoom/rotation).
    @Test(arguments: [
        (zoom: 0.119, offset: CGPoint(x: -20, y: -150)),
        (zoom: 1.0, offset: CGPoint(x: 700, y: 900)),
        (zoom: 3.0, offset: CGPoint(x: 6000, y: 4000)),
    ])
    func placedMarkerRoundTripsThroughViewport(entry: (zoom: CGFloat, offset: CGPoint)) {
        let tapScreen = CGPoint(x: 180, y: 340)
        let imagePoint = ViewportMath.toImage(
            screenPoint: tapScreen, zoomScale: entry.zoom, contentOffset: entry.offset
        )
        let action = MarkerTapResolver.resolve(
            tapImagePoint: imagePoint, markers: [], selectedID: nil, zoomScale: entry.zoom, imageSize: imageSize
        )
        guard case let .place(nx, ny) = action else {
            return // tap fell outside the plan at this viewport — nothing to round-trip
        }
        let rendered = ViewportMath.toScreen(
            imagePoint: ViewportMath.normalizedToImage(x: nx, y: ny, imageSize: imageSize),
            zoomScale: entry.zoom,
            contentOffset: entry.offset
        )
        #expect(abs(rendered.x - tapScreen.x) < 1e-6)
        #expect(abs(rendered.y - tapScreen.y) < 1e-6)
    }
}
