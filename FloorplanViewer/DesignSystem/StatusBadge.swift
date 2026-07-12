import SwiftUI

/// Compact package-state badge: icon + text + semantic tint — never color alone.
struct StatusBadge: View {
    let displayState: PackageDisplayState

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: .capsule)
            .accessibilityLabel(title)
    }

    private var title: String {
        switch displayState {
        case .preparing: "Preparing"
        case let .retrying(attempt): "Retrying (attempt \(attempt))"
        case .extracting: "Extracting"
        case .ready: "Available offline"
        case .failedWillRetry: "Failed — will retry"
        case .unavailableOffline: "Unavailable offline"
        }
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
