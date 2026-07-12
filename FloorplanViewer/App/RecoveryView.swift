import SwiftUI

/// Recoverable launch-failure screen: never a crash-loop. Retry re-attempts launch; Reset is a
/// confirmed destructive last resort.
struct RecoveryView: View {
    let error: AppLaunchError
    let onRetry: () -> Void
    let onReset: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.userMessage)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.borderedProminent)
            Button("Reset Local Data", systemImage: "trash", role: .destructive) {
                showResetConfirmation = true
            }
        }
        .confirmationDialog(
            "Reset Local Data?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes downloaded floorplans and markers. Projects are prepared again on next launch.")
        }
    }
}

#Preview {
    RecoveryView(
        error: .databaseOpenFailed(underlying: "preview"),
        onRetry: {},
        onReset: {}
    )
}
