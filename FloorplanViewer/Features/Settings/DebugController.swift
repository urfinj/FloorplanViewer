import Foundation

/// The one type the Debug / Demo sheet talks to. `@MainActor @Observable`: it holds view-facing
/// display state and forwards mutations to the lock-backed `DebugControls` / `DebugPathMonitor`
/// (read off-main by the downloader), or to the coordinator + repositories. Keeps GRDB and the
/// actor out of the SwiftUI view.
///
/// The two connectivity flags are persisted in `UserDefaults`, so they survive a reset (which wipes
/// the package store, never preferences) and the relaunch that follows.
@MainActor
@Observable
final class DebugController {
    /// Per-chunk delay applied while "Slow downloads" is on — deliberately heavy so the progress
    /// bar crawls visibly even on the fast sample packages.
    static let throttleDelayMillis = 1500

    private static let offlineKey = "debug.simulateOffline"
    private static let slowDownloadsKey = "debug.slowDownloads"

    /// Persisted connectivity flags, read by `DebugSupport` to seed the monitor / controls before
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
    private let projects: ProjectRepository
    private let coordinator: PackagePreparationCoordinator
    private let database: AppDatabase
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

    /// The URL the seeded demo project points at (a 404 today) — shown in the sheet so a reviewer
    /// knows where to upload a valid archive to make it succeed.
    var seed404URL: String {
        ProjectRepository.seed404URL
    }

    init(
        monitor: DebugPathMonitor,
        controls: DebugControls,
        connectivity: ConnectivityState,
        projects: ProjectRepository,
        coordinator: PackagePreparationCoordinator,
        database: AppDatabase,
        defaults: UserDefaults = .standard
    ) {
        self.monitor = monitor
        self.controls = controls
        self.connectivity = connectivity
        self.projects = projects
        self.coordinator = coordinator
        self.database = database
        self.defaults = defaults
        // Seed from the (already restored) knob values; initial assignment does not fire `didSet`,
        // so this neither re-persists nor clobbers the restored state.
        simulateOffline = monitor.isForcedOffline
        slowDownloads = controls.chunkDelayMillis > 0
    }

    /// Add one deliberately-failing demo project (a 404 "not found") and kick the engine so it runs
    /// straight to "Failed — will retry".
    func seed404Plan() async {
        do {
            try await projects.seed404Project()
        } catch {
            Log.app.error("Seed 404 plan failed: \(String(describing: error), privacy: .public)")
        }
        await coordinator.prepareAll()
    }

    /// Plain restart: terminate the process, keeping all on-disk data. The next launch re-runs the
    /// normal boot (catalog sync, recovery, auto-prepare) against the existing store. iOS has no
    /// self-relaunch, so the app closes — reopen it to continue.
    func reset() {
        exit(0)
    }

    /// Hard reset: erase the on-disk store (database + all package files), then terminate so the
    /// next launch is a clean first run. The connectivity flags live in `UserDefaults`, which the
    /// wipe does not touch, so they are restored on relaunch.
    ///
    /// Ordering is the safety contract — the caller confirms first (this erases the user's markers
    /// too), and the wipe must not race live work:
    ///   1. `coordinator.stop()` cancels **and joins** every in-flight pipeline, including the
    ///      shielded demote-writes a cancellation triggers — after it returns, nothing is writing.
    ///   2. `database.close()` checkpoints the WAL and releases the pool's file handles, so no open
    ///      connection races the deletion.
    ///   3. only then remove the container.
    func clearDataAndReset() async {
        await coordinator.stop()
        database.close()
        do {
            try await AppEnvironment.resetLocalStore()
        } catch {
            Log.app.error("Clear data and reset failed: \(String(describing: error), privacy: .public)")
        }
        exit(0)
    }
}
