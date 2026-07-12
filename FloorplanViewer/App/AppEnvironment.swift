import Foundation

/// Composition root. It builds and owns every concrete dependency; views receive already-built
/// feature models or protocol-typed collaborators. No singletons.
///
/// Phase 1 is intentionally near-empty — it exists to prove the launch/recovery flow. Later
/// phases add the database, clock, package storage, repositories, connectivity monitor, and the
/// preparation coordinator, plus `@concurrent openStore()` (the one blocking hop at launch).
@MainActor
final class AppEnvironment {
    private init() {}

    /// Builds the live composition root off the main actor where blocking work will live.
    nonisolated static func live() async throws -> AppEnvironment {
        #if DEBUG
            if ProcessInfo.processInfo.environment["FLOORPLAN_FORCE_LAUNCH_FAILURE"] != nil {
                throw AppLaunchError.databaseOpenFailed(underlying: "forced launch failure (debug)")
            }
        #endif
        return await AppEnvironment()
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
}
