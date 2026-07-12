import Foundation

/// Drives the launch state machine: `loading → ready(env) | failed(error)`. A failure is a
/// recoverable UI state (Retry re-runs `live`; Reset clears local data), never a crash.
@MainActor
@Observable
final class AppLauncher {
    enum Phase {
        case loading
        case ready(AppEnvironment)
        case failed(AppLaunchError)
    }

    private(set) var phase: Phase = .loading

    /// Called once from the root scene's `.task`.
    func start() async {
        guard case .loading = phase else { return }
        await load()
    }

    /// Retry after a failure: re-subscribe from `loading`.
    func retry() async {
        phase = .loading
        await load()
    }

    /// Destructive reset (confirmed in the UI). Phase 2 wires `AppContainer.reset()` before the
    /// reload; for now it simply re-attempts launch.
    func reset() async {
        phase = .loading
        await load()
    }

    private func load() async {
        switch await AppEnvironment.liveResult() {
        case let .success(environment):
            phase = .ready(environment)
        case let .failure(error):
            Log.app.error("Launch resolved to failure: \(String(describing: error), privacy: .public)")
            phase = .failed(error)
        }
    }
}
