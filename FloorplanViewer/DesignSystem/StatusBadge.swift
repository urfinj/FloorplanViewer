import SwiftUI

/// Compact package-state badge: icon + text + semantic tint — never color alone, and never
/// icon alone. Built from an explicit `HStack` rather than `Label` so no ancestor `labelStyle`
/// (sidebar/toolbar contexts resolve labels icon-only) can drop the title. Transient states
/// carry live progress in the text itself.
struct StatusBadge: View {
    let displayState: PackageDisplayState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch displayState {
        case let .preparing(progress):
            progress.map { "Downloading \(percent($0))" } ?? "Preparing"
        case let .retrying(attempt, progress):
            progress.map { "Retrying \(percent($0)) · attempt \(attempt)" } ?? "Retrying (attempt \(attempt))"
        case .extracting: "Extracting"
        case .ready: "Available offline"
        case .failedWillRetry: "Failed — will retry"
        case .unavailableOffline: "Unavailable offline"
        }
    }

    private func percent(_ progress: Double) -> String {
        progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var symbol: String {
        switch displayState {
        case .preparing: "arrow.down.circle"
        case .retrying: "arrow.clockwise.circle"
        case .extracting: "shippingbox"
        case .ready: "checkmark.circle.fill"
        case .failedWillRetry: "exclamationmark.triangle.fill"
        case .unavailableOffline: "wifi.slash"
        }
    }

    private var tint: Color {
        switch displayState {
        case .preparing, .retrying, .extracting: .accentColor
        case .ready: .green
        case .failedWillRetry: .orange
        case .unavailableOffline: .secondary
        }
    }
}
