import SwiftUI

/// The detail pane for a selected project. Phase 5 interim: renders the live display state
/// full-size (Phase 6 swaps the `.ready` branch for the native tiled viewer — the state
/// scaffolding around it stays).
struct FloorplanViewerScreen: View {
    let row: ProjectListRow
    let isOffline: Bool
    let onRetry: () -> Void

    private var displayState: PackageDisplayState {
        .make(row: row, isOffline: isOffline)
    }

    var body: some View {
        content
            .navigationTitle(row.name)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch displayState {
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
            // Phase 6 replaces this with the native tiled viewer.
            ContentUnavailableView {
                Label("Floorplan Ready", systemImage: "map")
            } description: {
                Text("The native tiled viewer arrives in the next phase.")
            }
        case .failedWillRetry:
            ContentUnavailableView {
                Label("Preparation Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The floorplan will be retried automatically.")
            } actions: {
                Button("Retry Now", systemImage: "arrow.clockwise", action: onRetry)
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
