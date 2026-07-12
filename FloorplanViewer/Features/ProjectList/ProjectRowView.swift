import SwiftUI

/// One project in the sidebar, organized as one clear column beside the thumbnail:
/// name → state-specific caption (progress / prepared time + marker count / failure + Retry) →
/// status badge. The badge lives in the column, not the trailing edge, so it never fights the
/// title for width and never wraps.
struct ProjectRowView: View {
    let row: ProjectListRow
    let previewURL: URL?
    let isOffline: Bool
    let onRetry: () -> Void

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityActions {
            if case .failedWillRetry = displayState {
                Button("Retry", action: onRetry)
            }
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        switch displayState {
        case let .preparing(progress?):
            progressLine(progress)
        case let .retrying(_, progress?):
            progressLine(progress)
        case .preparing, .extracting, .retrying:
            // The badge itself carries the transient status text (with live percent when
            // downloading) — no caption needed, so the row doesn't say it twice.
            EmptyView()
        case .ready:
            readyCaption
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failedWillRetry(reason, nextRetryAt):
            HStack(spacing: 12) {
                Text(retryCaption(reason: reason, nextRetryAt: nextRetryAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        case .unavailableOffline:
            Text("Waiting for connection")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            Text("\(row.name), preparation failed, will retry automatically")
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
