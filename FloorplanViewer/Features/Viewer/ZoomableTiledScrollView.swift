import SwiftUI
import UIKit

/// UIKit bridge for the tiled floorplan: UIScrollView owns pan/pinch/centering; the content view
/// is the CATiledLayer canvas in image-pixel space. Geometry is pushed into `ViewportState` for
/// the SwiftUI marker overlay; taps come back as image-space points (the content view's own
/// coordinate space — no math at the callback edge).
struct ZoomableTiledScrollView: UIViewRepresentable {
    let pyramid: TilePyramid
    let provider: TileProvider
    let viewport: ViewportState
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> LayoutCallbackScrollView {
        let content = TilingContentView(pyramid: pyramid, provider: provider)
        let scroll = LayoutCallbackScrollView()
        scroll.addSubview(content)
        scroll.contentSize = pyramid.fullSize
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        content.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: doubleTap)
        content.addGestureRecognizer(tap)

        context.coordinator.content = content
        scroll.onLayout = { [weak scroll, weak coordinator = context.coordinator] in
            guard let scroll, let coordinator else { return }
            coordinator.updateZoomLimits(scroll)
        }
        return scroll
    }

    func updateUIView(_: LayoutCallbackScrollView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.viewport = viewport
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewport: viewport, onTap: onTap)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var content: TilingContentView?
        var viewport: ViewportState
        var onTap: (CGPoint) -> Void
        private var lastFitScale: CGFloat?

        init(viewport: ViewportState, onTap: @escaping (CGPoint) -> Void) {
            self.viewport = viewport
            self.onTap = onTap
        }

        func viewForZooming(in _: UIScrollView) -> UIView? {
            content
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            recenter(scrollView)
            push(scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            push(scrollView)
        }

        /// Layout pass: (re)compute zoom limits from live bounds. First layout fits and centers;
        /// rotation/resize keeps a fitted view fitted and preserves manual zoom otherwise.
        func updateZoomLimits(_ scrollView: UIScrollView) {
            guard let content, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let fit = ViewportMath.fitScale(imageSize: content.bounds.size, boundsSize: scrollView.bounds.size)
            guard fit.isFinite, fit > 0 else { return }
            let wasAtFit = lastFitScale.map { abs(scrollView.zoomScale - $0) < 0.001 } ?? true
            scrollView.minimumZoomScale = fit
            scrollView.maximumZoomScale = ViewportMath.maxScale(fit: fit)
            if wasAtFit || scrollView.zoomScale < fit {
                scrollView.zoomScale = fit
                centerContent(scrollView)
            }
            lastFitScale = fit
            recenter(scrollView)
            push(scrollView)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let content else { return }
            // The content view's coordinate space IS image space (1 pt ≡ 1 px).
            onTap(recognizer.location(in: content))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let content, let scrollView = content.superview as? UIScrollView else { return }
            let fit = scrollView.minimumZoomScale
            if scrollView.zoomScale > fit * 1.01 {
                scrollView.setZoomScale(fit, animated: true)
            } else {
                let target = min(1, scrollView.maximumZoomScale)
                let point = recognizer.location(in: content)
                let size = CGSize(
                    width: scrollView.bounds.width / target,
                    height: scrollView.bounds.height / target
                )
                let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }

        /// Center the content while it is smaller than the viewport. `contentSize` is already
        /// zoom-scaled by UIScrollView; the leftover space becomes symmetric insets (driving
        /// `contentOffset` negative — `ViewportMath` holds unchanged).
        private func recenter(_ scrollView: UIScrollView) {
            let insetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let insetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        private func centerContent(_ scrollView: UIScrollView) {
            let scaledWidth = scrollView.contentSize.width
            let scaledHeight = scrollView.contentSize.height
            scrollView.contentOffset = CGPoint(
                x: (scaledWidth - scrollView.bounds.width) / 2,
                y: (scaledHeight - scrollView.bounds.height) / 2
            )
        }

        private func push(_ scrollView: UIScrollView) {
            viewport.update(
                zoomScale: scrollView.zoomScale,
                contentOffset: scrollView.contentOffset,
                boundsSize: scrollView.bounds.size
            )
        }
    }
}

/// UIScrollView with a layout hook — UIScrollViewDelegate has no layout callback, and zoom
/// limits need live bounds (first layout, rotation, split-view resize).
final class LayoutCallbackScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
