import os
import UIKit

/// The CATiledLayer-backed floorplan canvas. Its coordinate space is full-resolution image
/// pixels (frame = pyramid.fullSize, 1 pt ≡ 1 px), so scroll math, tap locations, and marker
/// anchors all share one space.
///
/// `CATiledLayer` invokes `draw(_:)` concurrently on **background threads** — the override is
/// explicitly `nonisolated` and touches only immutable `Sendable` state plus a lock-protected
/// scale snapshot maintained from MainActor lifecycle callbacks.
final class TilingContentView: UIView {
    private let pyramid: TilePyramid
    private let provider: TileProvider
    /// The layer's contentsScale, mirrored for the nonisolated draw path (`layer` itself is
    /// MainActor-isolated). Written on window attach; read per background tile draw.
    private let scaleBox = OSAllocatedUnfairLock<CGFloat>(initialState: 1)

    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    init(pyramid: TilePyramid, provider: TileProvider) {
        self.pyramid = pyramid
        self.provider = provider
        super.init(frame: CGRect(origin: .zero, size: pyramid.fullSize))
        backgroundColor = .white // plan paper behind not-yet-decoded tiles
        isOpaque = true
        configureTiledLayer(displayScale: 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// The display scale is only known once attached to a window; retune the layer for it so
    /// tiles rasterize at native resolution (sharp on Retina) and level math stays exact.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        configureTiledLayer(displayScale: max(1, traitCollection.displayScale))
    }

    private func configureTiledLayer(displayScale: CGFloat) {
        guard let tiled = layer as? CATiledLayer else { return }
        scaleBox.withLock { $0 = displayScale }
        tiled.contentsScale = displayScale
        tiled.levelsOfDetail = pyramid.levelCount
        // Keep rendering the full-res level sharp when over-zoomed past 1:1 (max zoom ≤ 8×fit).
        tiled.levelsOfDetailBias = 3
        // One draw callback ≈ one DZI tile at every LOD (both grids halve together). Set AFTER
        // contentsScale: CATiledLayer rescales tileSize itself when contentsScale changes.
        let side = CGFloat(pyramid.descriptor.tileSize) * displayScale
        tiled.tileSize = CGSize(width: side, height: side)
        setNeedsDisplay()
    }

    /// Called by CATiledLayer per tile, concurrently, off the main thread — hence explicitly
    /// `nonisolated` (a legal isolation relaxation for an override); it reads only immutable
    /// `Sendable` state and the lock-protected scale.
    override nonisolated func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let contentsScale = scaleBox.withLock { $0 }
        let lodScale = abs(ctx.ctm.a) / contentsScale
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
