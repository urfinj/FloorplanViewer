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
    let controller: ViewportController
    let onTap: (CGPoint) -> Void
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> LayoutCallbackScrollView {
        let content = TilingContentView(pyramid: pyramid, provider: provider, displayScale: displayScale)
        let scroll = LayoutCallbackScrollView()
        scroll.addSubview(content)
        scroll.contentSize = pyramid.fullSize
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        // Give the white plan paper a visible edge when letterboxed (esp. light mode).
        scroll.backgroundColor = .secondarySystemBackground

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
        // Imperative command path for the SwiftUI zoom buttons.
        controller.zoomBy = { [weak scroll, weak coordinator = context.coordinator] factor in
            guard let scroll, let coordinator else { return }
            coordinator.zoom(by: factor, on: scroll)
        }
        controller.zoomToFit = { [weak scroll] in
            guard let scroll else { return }
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
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
            viewport.updateLimits(minimum: fit, maximum: ViewportMath.maxScale(fit: fit))
            // Only re-fit when the user was already fitted (first layout, rotation at fit).
            // Never clamp `zoomScale < fit` here: layout runs during pinch, and the bounce
            // below minimum is UIScrollView's own gesture behavior — stomping it fights the pinch.
            if wasAtFit, lastFitScale != fit {
                scrollView.zoomScale = fit
                centerContent(scrollView)
            }
            lastFitScale = fit
            recenter(scrollView)
            push(scrollView)
            #if DEBUG
                applyDebugZoomIfRequested(scrollView)
            #endif
        }

        #if DEBUG
            /// Diagnosis without gesture automation: `FLOORPLAN_DEBUG_ZOOM=<scale>` in the launch
            /// environment zooms once after the first fitted layout, so a screenshot + the draw
            /// logs show exactly which DZI level renders at that zoom.
            private var debugZoomApplied = false
            private func applyDebugZoomIfRequested(_ scrollView: UIScrollView) {
                guard !debugZoomApplied,
                      let raw = ProcessInfo.processInfo.environment["FLOORPLAN_DEBUG_ZOOM"],
                      let requested = Double(raw)
                else { return }
                debugZoomApplied = true
                let target = min(max(CGFloat(requested), scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                Log.viewer.notice("Debug zoom: applying \(target, format: .fixed(precision: 3))")
                scrollView.setZoomScale(target, animated: false)
            }
        #endif

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let content else { return }
            // The content view's coordinate space IS image space (1 pt ≡ 1 px).
            onTap(recognizer.location(in: content))
        }

        /// Discrete zoom that keeps the image point under the viewport center pinned, animated as
        /// one ease-in-out. The screen-space center is `width / 2` — NOT `bounds.midX`, because a
        /// scroll view's `bounds.origin` IS `contentOffset`, and `toImage` adds the offset itself
        /// (using `midX` double-counts it and drifts the view sideways on every press).
        func zoom(by factor: CGFloat, on scrollView: UIScrollView) {
            let current = scrollView.zoomScale
            guard current > 0 else { return }
            let target = min(max(current * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            guard abs(target - current) > 0.0001 else { return }
            let viewportCenter = CGPoint(x: scrollView.bounds.width / 2, y: scrollView.bounds.height / 2)
            let anchor = ViewportMath.toImage(
                screenPoint: viewportCenter, zoomScale: current, contentOffset: scrollView.contentOffset
            )
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                scrollView.zoomScale = target // fires scrollViewDidZoom → recenter() refreshes insets
                let desired = CGPoint(
                    x: anchor.x * target - viewportCenter.x,
                    y: anchor.y * target - viewportCenter.y
                )
                scrollView.contentOffset = Self.clampedOffset(desired, in: scrollView)
            }
        }

        /// Legal offset range under the centering insets: small content pins to its centered
        /// offset (min == max == −inset); large content clamps to its edges.
        private static func clampedOffset(_ proposed: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let inset = scrollView.contentInset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            return CGPoint(
                x: min(max(proposed.x, minX), maxX),
                y: min(max(proposed.y, minY), maxY)
            )
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
