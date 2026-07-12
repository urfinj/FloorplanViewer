import Foundation

/// The one type the Debug / Demo sheet talks to. `@MainActor @Observable`: it holds view-facing
/// display state and forwards mutations to the lock-backed `DebugControls` / `DebugPathMonitor`
/// (read off-main by the downloader). Keeps GRDB and the coordinator actor out of the SwiftUI view.
///
/// The two connectivity flags are persisted in `UserDefaults`, so they survive **Clear and reset**
/// (which wipes only the package store, never preferences) and the relaunch that follows.
@MainActor
@Observable
final class DebugController {
    /// Per-chunk delay applied while "Slow downloads" is on — deliberately heavy so the progress
    /// bar crawls visibly even on the fast sample packages.
    static let throttleDelayMillis = 1500

    private static let offlineKey = "debug.simulateOffline"
    private static let slowDownloadsKey = "debug.slowDownloads"

    /// Persisted connectivity flags, read by `AppEnvironment` to seed the monitor / controls before
    /// the engine starts (so a restored "offline" is honoured from the first drain).
    static func persistedSimulateOffline(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: offlineKey)
    }

    static func persistedSlowDownloads(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: slowDownloadsKey)
    }

    private let monitor: DebugPathMonitor
    private let controls: DebugControls
    private let connectivity: ConnectivityState
    private let defaults: UserDefaults

    /// Forced-offline override. Writing it flips the shared path monitor and persists the flag.
    var simulateOffline: Bool {
        didSet {
            monitor.setForcedOffline(simulateOffline)
            defaults.set(simulateOffline, forKey: Self.offlineKey)
        }
    }

    /// Pace the download loop so the progress bar is observable (real bytes, just slower). Persisted.
    var slowDownloads: Bool {
        didSet {
            controls.setChunkDelayMillis(slowDownloads ? Self.throttleDelayMillis : 0)
            defaults.set(slowDownloads, forKey: Self.slowDownloadsKey)
        }
    }

    /// Real reachability, independent of the simulated override, for a legible read-only row.
    var realIsOffline: Bool {
        connectivity.isOffline
    }

    init(
        monitor: DebugPathMonitor,
        controls: DebugControls,
        connectivity: ConnectivityState,
        defaults: UserDefaults = .standard
    ) {
        self.monitor = monitor
        self.controls = controls
        self.connectivity = connectivity
        self.defaults = defaults
        // Seed from the (already restored) knob values; initial assignment does not fire `didSet`,
        // so this neither re-persists nor clobbers the restored state.
        simulateOffline = monitor.isForcedOffline
        slowDownloads = controls.chunkDelayMillis > 0
    }

    /// Hard reset: erase the on-disk store (database + all package files), then terminate the
    /// process so the next launch is a clean first run — fresh migration, seed, and automatic
    /// preparation from zero. The connectivity flags live in `UserDefaults`, which the wipe does
    /// not touch, so they are restored on relaunch. iOS has no supported self-relaunch, so the app
    /// closes; reopening it shows the full cold-start download flow.
    func clearAndReset() async {
        do {
            try await AppEnvironment.resetLocalStore()
        } catch {
            Log.app.error("Clear and reset failed: \(String(describing: error), privacy: .public)")
        }
        exit(0)
    }
}
