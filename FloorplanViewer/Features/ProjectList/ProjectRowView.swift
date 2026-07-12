import SwiftUI

/// One project in the sidebar: name, state badge, and the state-specific second line
/// (progress while downloading — first attempt or retry; failure + relative retry time +
/// manual Retry when failed).
struct ProjectRowView: View {
    let row: ProjectListRow
    let isOffline: Bool
    let onRetry: () -> Void

    private var displayState: PackageDisplayState {
        .make(row: row, isOffline: isOffline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.body.weight(.medium))
                Spacer()
                StatusBadge(displayState: displayState)
            }
            secondLine
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var secondLine: some View {
        switch displayState {
        case let .preparing(progress?):
            progressLine(progress)
        case let .retrying(_, progress?):
            progressLine(progress)
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
        default:
            EmptyView()
        }
    }

    private func progressLine(_ progress: Double) -> some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
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
