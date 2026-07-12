import SwiftUI

/// One project in the sidebar: name, state badge, and the state-specific second line
/// (progress while downloading; failure + relative retry time + manual Retry when failed).
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
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
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

    private func retryCaption(reason: PackageFailureReason, nextRetryAt: Double?) -> String {
        var caption = failureText(reason)
        if let nextRetryAt {
            let date = Date(timeIntervalSince1970: nextRetryAt)
            if date > Date() {
                caption += " · retries \(date.formatted(.relative(presentation: .numeric)))"
            }
        }
        return caption
    }

    private func failureText(_ reason: PackageFailureReason) -> String {
        switch reason {
        case .network: "Network problem"
        case .httpStatus: "Server error"
        case .corruptArchive: "Damaged download"
        case .extractionFailed: "Couldn’t unpack"
        case .descriptorNotFound, .descriptorInvalid, .tilesMissing: "Package content invalid"
        case .diskFull: "Not enough storage"
        case .unknown: "Something went wrong"
        }
    }
}
