import SwiftUI

/// The detail pane for one project: state scaffolding around the native tiled viewer. Renders by
/// live display state and auto-flips into the viewer the moment the package is ready — content
/// comes only from the awaited `packageForViewing` handshake inside the model.
struct FloorplanViewerScreen: View {
    @State private var model: ViewerViewModel

    init(model: ViewerViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.observePackage() }
            .task { await model.observeMarkers() }
            .toolbar { viewerToolbar }
    }

    private var navigationTitle: String {
        // Project names are "Project N" derived from the id; the row name isn't observed here.
        model.projectID.replacingOccurrences(of: "project-", with: "Project ")
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
                )
                .ignoresSafeArea(edges: .bottom)
            }
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
                Label("\(model.markers.count)", systemImage: "mappin.and.ellipse")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(model.markers.count) markers")
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.displayState {
        case let .preparing(progress):
            VStack(spacing: 16) {
                if let progress {
                    ProgressView(value: progress) {
                        Text("Downloading floorplan…")
                    } currentValueLabel: {
                        Text("\(Int(progress * 100))%")
                    }
                    .frame(maxWidth: 280)
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing floorplan…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .retrying(attempt):
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Retrying (attempt \(attempt))…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failedWillRetry:
            ContentUnavailableView {
                Label("Preparation Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The floorplan will be retried automatically.")
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
}
