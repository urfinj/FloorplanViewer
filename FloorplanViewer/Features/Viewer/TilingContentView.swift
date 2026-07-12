import UIKit

/// The CATiledLayer-backed floorplan canvas. Its coordinate space is full-resolution image
/// pixels (frame = pyramid.fullSize, 1 pt ≡ 1 px), so scroll math, tap locations, and marker
/// anchors all share one space.
///
/// **Scale model.** The tile backing store's pixel density is `LOD scale × contentsScale`, so
/// Retina sharpness requires `contentsScale = displayScale` — it is set exactly **once, at
/// init**, before the layer ever tiles (reconfiguring a live CATiledLayer mid-flight is what
/// caused stale low-res levels to linger). In `draw`, `ctm.a = LOD × contentsScale`; dividing by
/// the immutable `displayScale` recovers the LOD, and the DZI level is chosen for
/// `LOD × displayScale` so the level's pixels match the backing store's density 1:1.
///
/// `CATiledLayer` invokes `draw(_:)` concurrently on **background threads** — the override is
/// explicitly `nonisolated` and touches only immutable `Sendable` state.
final class TilingContentView: UIView {
    private let pyramid: TilePyramid
    private let provider: TileProvider
    private let displayScale: CGFloat

    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    /// UIKit re-stamps this on window attach; hold it at the density the layer was tiled for.
    override var contentScaleFactor: CGFloat {
        get { super.contentScaleFactor }
        set { _ = newValue; super.contentScaleFactor = displayScale }
    }

    init(pyramid: TilePyramid, provider: TileProvider, displayScale: CGFloat) {
        self.pyramid = pyramid
        self.provider = provider
        self.displayScale = max(1, displayScale)
        super.init(frame: CGRect(origin: .zero, size: pyramid.fullSize))
        backgroundColor = .white // plan paper behind not-yet-decoded tiles
        isOpaque = true
        if let tiled = layer as? CATiledLayer {
            tiled.contentsScale = self.displayScale
            tiled.levelsOfDetail = pyramid.levelCount
            // Headroom above LOD 1 for pinch bounce past max zoom.
            tiled.levelsOfDetailBias = 1
            // In pixels: one draw callback ≈ one DZI tile at every LOD (both grids halve together).
            let side = CGFloat(pyramid.descriptor.tileSize) * self.displayScale
            tiled.tileSize = CGSize(width: side, height: side)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// Called by CATiledLayer per tile, concurrently, off the main thread — hence explicitly
    /// `nonisolated` (a legal isolation relaxation for an override); it reads only immutable
    /// `Sendable` state.
    override nonisolated func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let lodScale = abs(ctx.ctm.a) / displayScale
        // Choose the DZI level whose pixels match the backing density (LOD × displayScale).
        let level = pyramid.folderLevel(forLODScale: lodScale * displayScale)
        #if DEBUG
            Log.viewer.debug("""
            tile draw: ctm=\(ctx.ctm.a, format: .fixed(precision: 3)) \
            lod=\(lodScale, format: .fixed(precision: 3)) level=\(level) \
            rect=(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))
            """)
        #endif
        let (cols, rows) = pyramid.tileIndices(intersecting: rect, atLevel: level)
        for row in rows {
            for col in cols {
                guard let image = provider.tileImage(level: level, col: col, row: row) else { continue }
                image.draw(in: pyramid.tileFrameInImageSpace(level: level, col: col, row: row))
            }
        }
    }
}
