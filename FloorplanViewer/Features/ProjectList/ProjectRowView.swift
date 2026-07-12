import SwiftUI

/// One project in the sidebar, organized as one clear column beside the thumbnail:
/// name → state-specific caption (progress / prepared time + marker count / failure) → status
/// badge. The badge lives in the column, not the trailing edge, so it never fights the title for
/// width and never wraps. Tapping the row opens the plan screen, which carries the Retry action.
struct ProjectRowView: View {
    let row: ProjectListRow
    let previewURL: URL?
    let isOffline: Bool

    private var displayState: PackageDisplayState {
        .make(row: row, isOffline: isOffline)
    }

    var body: some View {
        HStack(spacing: 12) {
            FloorplanThumbnail(previewURL: previewURL, displayState: displayState)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name)
                    .font(.body.weight(.semibold))
                secondLine
                StatusBadge(displayState: displayState)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // Cross-fade state changes so a fast retry loop (e.g. a 404 that fails, backs off, retries)
        // reads as a calm transition instead of a hard blink of the badge/thumbnail/caption.
        .animation(.easeInOut(duration: 0.3), value: displayState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    @ViewBuilder
    private var secondLine: some View {
        switch displayState {
        case let .preparing(progress?):
            progressLine(progress)
        case .preparing, .extracting:
            // The badge carries the transient status text — no caption needed here.
            EmptyView()
        case .retrying:
            // Stable caption — same shape as `.failedWillRetry` — so the brief in-flight attempt of
            // a fast-failing plan doesn't blink the cell. Retry lives on the plan screen, not here.
            caption("Retrying…")
        case .ready:
            readyCaption
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failedWillRetry(reason, nextRetryAt):
            caption(retryCaption(reason: reason, nextRetryAt: nextRetryAt))
        case .unavailableOffline:
            caption("Waiting for connection")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func progressLine(_ progress: Double) -> some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
    }

    /// "Updated 2 hours ago · 2 markers" — the timestamp only once a success has been stamped.
    private var readyCaption: Text {
        if let updatedAgo {
            Text("Updated \(updatedAgo) · ^[\(row.markerCount) marker](inflect: true)")
        } else {
            Text("^[\(row.markerCount) marker](inflect: true)")
        }
    }

    private var updatedAgo: String? {
        guard let lastSuccessAt = row.lastSuccessAt else { return nil }
        let date = Date(timeIntervalSince1970: lastSuccessAt)
        let now = Date()
        guard date <= now else { return nil }
        // Floor sub-minute ages to a stable phrase — otherwise a relative style ticks every
        // second ("3 seconds ago", "4 seconds ago", …). Minute+ ages already read as whole minutes.
        if now.timeIntervalSince(date) < 60 {
            return "just now"
        }
        return date.formatted(.relative(presentation: .named))
    }

    private var rowAccessibilityLabel: Text {
        switch displayState {
        case let .preparing(progress?):
            Text("\(row.name), downloading, \(Int(progress * 100)) percent")
        case let .retrying(_, progress?):
            Text("\(row.name), retrying, \(Int(progress * 100)) percent")
        case .preparing, .extracting, .retrying:
            Text("\(row.name), preparing")
        case .ready:
            Text("\(row.name), available offline, ^[\(row.markerCount) marker](inflect: true)")
        case .failedWillRetry:
            Text("\(row.name), preparation failed, manual retry available")
        case .unavailableOffline:
            Text("\(row.name), not available offline")
        }
    }

    private func retryCaption(reason: PackageFailureReason, nextRetryAt: Double?) -> String {
        var caption = reason.userDescription
        if let nextRetryAt {
            let date = Date(timeIntervalSince1970: nextRetryAt)
            if date > Date() {
                caption += " · retries \(date.formatted(.relative(presentation: .numeric)))"
            }
        }
        return caption
    }
}
