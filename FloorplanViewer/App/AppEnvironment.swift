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

    /// Pure DI initializer — tests inject an in-memory DB, a `TestClock`, and a scratch storage.
    init(database: AppDatabase, clock: any AppClock, storage: PackageStorage) {
        self.database = database
        self.clock = clock
        self.storage = storage
        let writer = database.writer
        projectRepository = ProjectRepository(dbWriter: writer)
        packageRepository = PackageRepository(dbWriter: writer, clock: clock)
        markerRepository = MarkerRepository(dbWriter: writer, clock: clock)
        appStateRepository = AppStateRepository(dbWriter: writer, clock: clock)
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
        return await AppEnvironment(database: store.database, clock: SystemClock(), storage: store.storage)
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
