import UIKit

/// The CATiledLayer-backed floorplan canvas. Its coordinate space is full-resolution image
/// pixels (frame = pyramid.fullSize, 1 pt ≡ 1 px), so scroll math, tap locations, and marker
/// anchors all share one space.
///
/// **Scale recipe (canonical tiled-scroll-view approach):** `contentScaleFactor` is pinned to 1
/// — UIKit force-sets the screen scale when the view joins a window, which makes CATiledLayer
/// rescale its `tileSize` and re-bucket levels of detail out from under the level math (symptom:
/// high-resolution levels never render; the plan stays an upscaled blur). With the layer's
/// `contentsScale` fixed at 1, `ctx.ctm.a` in `draw` is exactly the rendered LOD scale, and
/// `levelsOfDetailBias` supplies the Retina/over-zoom headroom.
///
/// `CATiledLayer` invokes `draw(_:)` concurrently on **background threads** — the override is
/// explicitly `nonisolated` and touches only immutable `Sendable` state.
final class TilingContentView: UIView {
    private let pyramid: TilePyramid
    private let provider: TileProvider

    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    /// UIKit assigns the screen scale on window attach; keep the tiled layer at 1 (see header).
    override var contentScaleFactor: CGFloat {
        get { super.contentScaleFactor }
        set { _ = newValue; super.contentScaleFactor = 1 }
    }

    init(pyramid: TilePyramid, provider: TileProvider) {
        self.pyramid = pyramid
        self.provider = provider
        super.init(frame: CGRect(origin: .zero, size: pyramid.fullSize))
        backgroundColor = .white // plan paper behind not-yet-decoded tiles
        isOpaque = true
        if let tiled = layer as? CATiledLayer {
            tiled.contentsScale = 1
            tiled.levelsOfDetail = pyramid.levelCount
            // Render up to 4× above LOD 1: covers Retina sharpness at max zoom and pinch bounce.
            tiled.levelsOfDetailBias = 2
            let side = CGFloat(pyramid.descriptor.tileSize)
            tiled.tileSize = CGSize(width: side, height: side) // 1 draw callback ≈ 1 DZI tile
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// Called by CATiledLayer per tile, concurrently, off the main thread — hence explicitly
    /// `nonisolated` (a legal isolation relaxation for an override); it reads only immutable
    /// `Sendable` state. With contentsScale pinned to 1, `ctm.a` IS the LOD scale.
    override nonisolated func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let lodScale = abs(ctx.ctm.a)
        let level = pyramid.folderLevel(forLODScale: lodScale)
        let (cols, rows) = pyramid.tileIndices(intersecting: rect, atLevel: level)
        for row in rows {
            for col in cols {
                guard let image = provider.tileImage(level: level, col: col, row: row) else { continue }
                image.draw(in: pyramid.tileFrameInImageSpace(level: level, col: col, row: row))
            }
        }
    }
}
