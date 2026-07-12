import SwiftUI

/// App entry.
@main
struct FloorplanViewerApp: App {
    @State private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup {
            content
                .task { await launcher.start() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch launcher.phase {
        case .loading:
            LaunchView()
        case let .ready(environment):
            RootView(environment: environment)
        case let .failed(error):
            RecoveryView(
                error: error,
                onRetry: { Task { await launcher.retry() } },
                onReset: { Task { await launcher.reset() } }
            )
        }
    }
}
