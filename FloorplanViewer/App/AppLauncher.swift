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
    /// Serializes launch/retry/reset. Changing `phase` to `.loading` can cause the root `.task`
    /// to run again while a button-triggered retry is already suspended in `liveResult()`.
    private var launchInProgress = false

    /// Called once from the root scene's `.task`.
    func start() async {
        guard case .loading = phase else { return }
        await launch(resetFirst: false)
    }

    /// Retry after a failure: re-subscribe from `loading`.
    func retry() async {
        await launch(resetFirst: false)
    }

    /// Destructive reset (confirmed in the UI): clear the local store, then re-attempt launch.
    func reset() async {
        await launch(resetFirst: true)
    }

    private func launch(resetFirst: Bool) async {
        guard !launchInProgress else { return }
        launchInProgress = true
        defer { launchInProgress = false }
        phase = .loading

        if resetFirst {
            do {
                try await AppEnvironment.resetLocalStore()
            } catch {
                Log.app.error("Local store reset failed: \(String(describing: error), privacy: .public)")
            }
        }
        switch await AppEnvironment.liveResult() {
        case let .success(environment):
            phase = .ready(environment)
        case let .failure(error):
            Log.app.error("Launch resolved to failure: \(String(describing: error), privacy: .public)")
            phase = .failed(error)
        }
    }
}
