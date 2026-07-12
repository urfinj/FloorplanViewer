import SwiftUI

/// The detail pane for one project: state scaffolding around the native tiled viewer. Renders by
/// live display state and auto-flips into the viewer the moment the package is ready — content
/// comes only from the awaited `packageForViewing` handshake inside the model.
struct FloorplanViewerScreen: View {
    let title: String
    @State private var model: ViewerViewModel

    init(title: String, model: ViewerViewModel) {
        self.title = title
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.content != nil, model.displayState == .ready, !model.markers.isEmpty {
                        markerCountBadge
                    }
                }
            }
            .sheet(item: selectionBinding) { marker in
                MarkerInspectorSheet(
                    marker: marker,
                    number: model.markerNumber(for: marker),
                    onDelete: { model.deleteSelectedMarker() },
                    onClose: { model.deselectMarker() }
                )
            }
    }

    /// Bridges the model's optional selection to `sheet(item:)`; any dismissal (drag, Close,
    /// tap-away, delete) deselects. Carries no logic beyond that deselect.
    private var selectionBinding: Binding<Marker?> {
        Binding(
            get: { model.selectedMarker },
            set: {
                if $0 == nil {
                    model.deselectMarker()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if let viewerContent = model.content, model.displayState == .ready {
            ZStack {
                ZoomableTiledScrollView(
                    pyramid: viewerContent.pyramid,
                    provider: viewerContent.provider,
                    viewport: model.viewport,
                    controller: model.viewportController
                ) { imagePoint in
                    model.handleTap(imagePoint: imagePoint)
                }
                .overlay { centerReticle }
                .ignoresSafeArea(edges: .bottom)
                MarkerOverlayView(
                    markers: model.markers,
                    selectedID: model.selectedMarkerID,
                    viewport: model.viewport,
                    imageSize: viewerContent.imageSize
                ) { markerID in
                    model.toggleSelection(of: markerID)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .bottom) {
                bottomControls
            }
            .overlay(alignment: .bottomTrailing) {
                zoomCluster
            }
            .animation(.default, value: model.markers.isEmpty)
            .sensoryFeedback(.impact(weight: .medium), trigger: model.markers.count)
            .sensoryFeedback(.selection, trigger: model.selectedMarkerID)
        } else {
            stateView
        }
    }

    // MARK: - Header + canvas overlays

    /// Read-only pin counter in the navigation bar's trailing slot. Deliberately a plain label in
    /// neutral colors — not a button, and it shouldn't look like one.
    private var markerCountBadge: some View {
        Label("\(model.markers.count)", systemImage: "mappin.and.ellipse")
            .labelStyle(.titleAndIcon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("^[\(model.markers.count) marker](inflect: true) placed")
    }

    /// Subtle crosshair marking exactly where "Drop Pin at Center" lands. Overlaid on the scroll
    /// view itself (before the safe-area expansion), so its center IS the viewport center the
    /// placement math uses.
    private var centerReticle: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.55), lineWidth: 1)
                .frame(width: 24, height: 24)
            Rectangle()
                .fill(.secondary.opacity(0.55))
                .frame(width: 14, height: 1)
            Rectangle()
                .fill(.secondary.opacity(0.55))
                .frame(width: 1, height: 14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hintPill: some View {
        Text("Tap the floorplan to drop a marker")
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: .capsule)
            .transition(.opacity)
    }

    /// Bottom-center placement control: the first-marker hint stacked above the oval drop button,
    /// which sits directly under the reticle it aims with.
    private var bottomControls: some View {
        VStack(spacing: 10) {
            if model.markers.isEmpty {
                hintPill
            }
            Button {
                model.placeMarkerAtViewportCenter()
            } label: {
                Label("Drop Pin", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.bottom, 12)
    }

    /// Zoom ±, visually icon-only — the text stays for VoiceOver. Both icons get the same fixed
    /// frame: the bare −/+ glyphs differ in intrinsic size, and the circular border shape would
    /// otherwise produce visibly different button diameters.
    private var zoomCluster: some View {
        VStack(spacing: 12) {
            Button {
                model.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus")
                    .frame(width: 24, height: 24)
            }
            .disabled(!model.viewport.canZoomIn)
            Button {
                model.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus")
                    .frame(width: 24, height: 24)
            }
            .disabled(!model.viewport.canZoomOut)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(16)
    }

    // MARK: - Non-ready states

    @ViewBuilder
    private var stateView: some View {
        switch model.displayState {
        case let .preparing(progress):
            FloorplanLoadingView(
                status: progress == nil ? "Preparing floorplan" : "Downloading floorplan",
                detail: "Saving this plan for offline use.",
                progress: progress
            )
        case let .retrying(attempt, progress):
            FloorplanLoadingView(
                status: "Retrying floorplan",
                detail: "Attempt \(attempt) · your existing offline data stays safe.",
                progress: progress
            )
        case .extracting:
            FloorplanLoadingView(
                status: "Preparing tiles",
                detail: "Finishing the offline floorplan package.",
                progress: nil
            )
        case .ready:
            // Ready row, content still opening via the handshake.
            FloorplanLoadingView(
                status: "Opening floorplan",
                detail: "Loading the tiled canvas…",
                progress: nil
            )
        case let .failedWillRetry(reason, nextRetryAt):
            ContentUnavailableView {
                Label("Preparation Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failureDescription(reason: reason, nextRetryAt: nextRetryAt))
            } actions: {
                Button("Retry Now", systemImage: "arrow.clockwise") { model.retryNow() }
                    .buttonStyle(.borderedProminent)
            }
        case .unavailableOffline:
            ContentUnavailableView {
                Label("Unavailable Offline", systemImage: "wifi.slash")
            } description: {
                Text("This floorplan hasn’t been prepared yet. It will download automatically when you’re back online.")
            }
        }
    }

    private func failureDescription(reason: PackageFailureReason, nextRetryAt: Double?) -> String {
        var text = "\(reason.userDescription)."
        if let nextRetryAt, Date(timeIntervalSince1970: nextRetryAt) > Date() {
            let when = Date(timeIntervalSince1970: nextRetryAt).formatted(.relative(presentation: .numeric))
            text += " Retries automatically \(when)."
        } else {
            text += " The floorplan will be retried automatically."
        }
        return text
    }
}
