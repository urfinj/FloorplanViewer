import SwiftUI

/// A rounded floorplan thumbnail for a list row. Shows the package's downsampled `preview.jpg`
/// once the package is `ready` and the file is on disk; otherwise a state-appropriate glyph.
/// Decoding happens off the main actor and is cached, so scrolling never decodes a full image.
struct FloorplanThumbnail: View {
    let previewURL: URL?
    let displayState: PackageDisplayState

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 56
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay { content }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 10))
            .task(id: taskID) { await load() }
            .accessibilityHidden(true) // the row's combined label already conveys state
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: placeholderSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    /// Reload when the path appears (package flips to `ready`) or the state glyph must change.
    private var taskID: String {
        "\(previewURL?.path ?? "none")|\(displayState == .ready)"
    }

    private var placeholderSymbol: String {
        switch displayState {
        case .preparing, .extracting, .retrying: "arrow.down.circle"
        case .failedWillRetry: "exclamationmark.triangle"
        case .unavailableOffline: "wifi.slash"
        case .ready: "square.grid.3x3" // ready but no preview file on disk
        }
    }

    private func load() async {
        let requestedTaskID = taskID
        guard displayState == .ready, let previewURL else {
            image = nil
            return
        }
        let loaded = await ThumbnailLoader.shared.thumbnail(at: previewURL, side: side, scale: displayScale)
        guard !Task.isCancelled, taskID == requestedTaskID else { return }
        image = loaded
    }
}
