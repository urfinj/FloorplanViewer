import Foundation

/// Single assembly point for the Debug / Demo surface. Everything debug-related is reachable from
/// here, so removing the feature is: delete `Core/Debug/` + `Features/Settings/`, then revert the
/// four `debug.*` references in `AppEnvironment` and the one `.debugSettingsGear` line in
/// `RootView`. Nothing debug-specific leaks into the engine — the downloader receives only a
/// generic `interChunkPause` closure, never a debug type.
@MainActor
final class DebugSupport {
    /// The monitor the whole app must use: the base monitor wrapped with the force-offline override.
    let pathMonitor: any PathMonitoring
    /// The downloader's only debug seam — a generic pause invoked after each chunk (inert when the
    /// "Slow downloads" throttle is off).
    let interChunkPause: @Sendable () async throws -> Void

    private let monitor: DebugPathMonitor
    private let controls: DebugControls

    init(basePathMonitor: any PathMonitoring) {
        let monitor = DebugPathMonitor(wrapping: basePathMonitor)
        let controls = DebugControls()
        // Restore the persisted connectivity flags before the engine reads the monitor / controls,
        // so a "Clear and reset" (which wipes the store but not preferences) comes back with the
        // same offline / slow-download state.
        if DebugController.persistedSimulateOffline() {
            monitor.setForcedOffline(true)
        }
        if DebugController.persistedSlowDownloads() {
            controls.setChunkDelayMillis(DebugController.throttleDelayMillis)
        }
        self.monitor = monitor
        self.controls = controls
        pathMonitor = monitor
        interChunkPause = {
            let millis = controls.chunkDelayMillis
            if millis > 0 {
                try await Task.sleep(for: .milliseconds(millis))
            }
        }
    }

    func makeController(connectivity: ConnectivityState) -> DebugController {
        DebugController(monitor: monitor, controls: controls, connectivity: connectivity)
    }
}
