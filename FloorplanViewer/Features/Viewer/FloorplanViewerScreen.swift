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
            .task { await model.observePackage() }
            .task { await model.observeMarkers() }
            .toolbar { viewerToolbar }
    }

    @ViewBuilder
    private var content: some View {
        if let viewerContent = model.content, model.displayState == .ready {
            ZStack {
                ZoomableTiledScrollView(
                    pyramid: viewerContent.pyramid,
                    provider: viewerContent.provider,
                    viewport: model.viewport
                ) { imagePoint in
                    model.handleTap(imagePoint: imagePoint)
                }
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
                if model.markers.isEmpty {
                    Text("Tap the floorplan to drop a marker")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: .capsule)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: model.markers.count)
            .sensoryFeedback(.selection, trigger: model.selectedMarkerID)
        } else {
            stateView
        }
    }

    @ToolbarContentBuilder
    private var viewerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.content != nil, model.displayState == .ready {
                if model.selectedMarkerID != nil {
                    Button("Delete Marker", systemImage: "trash", role: .destructive) {
                        model.deleteSelectedMarker()
                    }
                }
                if !model.markers.isEmpty {
                    Label("\(model.markers.count)", systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(model.markers.count) markers")
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.displayState {
        case let .preparing(progress):
            downloadProgressView(progress, caption: "Preparing floorplan…")
        case let .retrying(attempt, progress):
            downloadProgressView(progress, caption: "Retrying (attempt \(attempt))…")
        case .extracting:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Extracting floorplan…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            // Ready row, content still opening via the handshake.
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Opening floorplan…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func downloadProgressView(_ progress: Double?, caption: String) -> some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress) {
                    Text(caption)
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                .frame(maxWidth: 280)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
