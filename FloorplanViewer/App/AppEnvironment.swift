import Foundation

/// Composition root. Builds and owns every concrete dependency; views receive already-built
/// feature models or protocol-typed collaborators. No singletons.
///
/// Phase 2 adds the store, clock, package storage, and repositories. Later phases add the
/// preparation coordinator, connectivity, and launch recovery.
@MainActor
final class AppEnvironment {
    let clock: any AppClock
    let database: AppDatabase
    let storage: PackageStorage
    let projectRepository: ProjectRepository
    let packageRepository: PackageRepository
    let markerRepository: MarkerRepository
    let appStateRepository: AppStateRepository
    /// One shared monitor: the coordinator and the UI's connectivity state are two sinks on it.
    let pathMonitor: any PathMonitoring
    let coordinator: PackagePreparationCoordinator
    let launchRecovery: LaunchRecovery
    /// Shared live-reachability for display mapping (second sink on `pathMonitor`).
    let connectivity: ConnectivityState
    /// Debug / Demo facade for the settings sheet. Every seam it drives defaults inert, so
    /// production behaviour is unchanged until a toggle is flipped (see plan `09`).
    let debugController: DebugController

    /// Pure DI initializer — tests inject an in-memory DB, a `TestClock`, scratch storage, and a
    /// stub monitor.
    init(
        database: AppDatabase,
        clock: any AppClock,
        storage: PackageStorage,
        pathMonitor: any PathMonitoring = NWPathMonitorAdapter()
    ) {
        self.database = database
        self.clock = clock
        self.storage = storage
        // Debug / Demo surface — assembled entirely by `DebugSupport`. To remove the feature:
        // delete `Core/Debug/` + `Features/Settings/`, then revert these `debug.*` references and
        // the `.debugSettingsGear` line in `RootView`. Nothing debug-specific reaches the engine —
        // the downloader gets only a generic `interChunkPause` closure, the rest is the wrapped
        // path monitor (force-offline override) both the engine and UI already share.
        let debug = DebugSupport(basePathMonitor: pathMonitor)
        self.pathMonitor = debug.pathMonitor
        let writer = database.writer
        let projectRepository = ProjectRepository(dbWriter: writer)
        let packageRepository = PackageRepository(dbWriter: writer, clock: clock)
        self.projectRepository = projectRepository
        self.packageRepository = packageRepository
        let markerRepository = MarkerRepository(dbWriter: writer, clock: clock)
        let appStateRepository = AppStateRepository(dbWriter: writer, clock: clock)
        self.markerRepository = markerRepository
        self.appStateRepository = appStateRepository
        launchRecovery = LaunchRecovery(packages: packageRepository, storage: storage)
        let coordinator = PackagePreparationCoordinator(
            packages: packageRepository,
            projects: projectRepository,
            storage: storage,
            downloader: URLSessionPackageDownloader(interChunkPause: debug.interChunkPause),
            extractor: SWCompressionArchiveExtractor(),
            validator: DZIPackageValidator(),
            pathMonitor: debug.pathMonitor,
            clock: clock,
            // Calmer retry cadence than the type's baseline: first auto-retry after ~5–10s, then
            // doubling — a persistently-failing plan (e.g. a 404) re-attempts sparingly, not every
            // couple of seconds. The assignment leaves the exact strategy to us (reasonable + documented).
            backoff: BackoffPolicy(base: 10)
        )
        self.coordinator = coordinator
        let connectivity = ConnectivityState(monitor: debug.pathMonitor)
        self.connectivity = connectivity
        debugController = debug.makeController(
            connectivity: connectivity, projects: projectRepository, coordinator: coordinator, database: database
        )
    }

    /// One viewer model per selected project (`.id(projectID)` gives per-project identity).
    func makeViewerModel(projectID: String) -> ViewerViewModel {
        ViewerViewModel(
            projectID: projectID,
            packages: packageRepository,
            markerRepository: markerRepository,
            preparation: coordinator,
            connectivity: connectivity,
            storage: storage
        )
    }

    /// Builds the live composition root, opening the store off the main actor.
    nonisolated static func live() async throws -> AppEnvironment {
        #if DEBUG
            if ProcessInfo.processInfo.environment["FLOORPLAN_FORCE_LAUNCH_FAILURE"] != nil {
                throw AppLaunchError.databaseOpenFailed(underlying: "forced launch failure (debug)")
            }
        #endif
        let store: (database: AppDatabase, storage: PackageStorage)
        do {
            store = try await openStore()
        } catch {
            Log.app.error("Store open failed: \(String(describing: error), privacy: .public)")
            throw AppLaunchError.databaseOpenFailed(underlying: String(describing: error))
        }
        let environment = await AppEnvironment(
            database: store.database, clock: SystemClock(), storage: store.storage
        )
        // Catalog sync + recovery run before the launcher flips `.ready`: no UI — and no
        // preparation — ever observes stale endpoints or an unreconciled store.
        do {
            try await environment.projectRepository.synchronizeCatalog()
            try await environment.launchRecovery.recover()
        } catch {
            Log.app.error("Catalog sync or launch recovery failed: \(String(describing: error), privacy: .public)")
            throw AppLaunchError.recoveryFailed(underlying: String(describing: error))
        }
        return environment
    }

    /// Non-throwing wrapper the launcher awaits: resolves the root into a `Result`.
    nonisolated static func liveResult() async -> Result<AppEnvironment, AppLaunchError> {
        do {
            return try await .success(live())
        } catch let error as AppLaunchError {
            return .failure(error)
        } catch {
            Log.app.error("Launch failed: \(String(describing: error), privacy: .public)")
            return .failure(.databaseOpenFailed(underlying: String(describing: error)))
        }
    }

    /// The one blocking hop at launch: open the WAL pool + migrate + create the packages dir.
    @concurrent
    private nonisolated static func openStore() async throws -> (database: AppDatabase, storage: PackageStorage) {
        let database = try AppDatabase.makeShared()
        let packagesURL = try AppContainer.packagesURL()
        return (database, PackageStorage(root: packagesURL))
    }

    /// Destructive last resort behind a confirmation in `RecoveryView`.
    @concurrent
    nonisolated static func resetLocalStore() async throws {
        try AppContainer.reset()
        Log.app.notice("Local store reset requested.")
    }
}
