import Foundation
import Testing
@testable import FloorplanViewer

/// The debug "Seed 404 plan" affordance: one extra project (a 404) inserted alongside the three
/// seeded ones, in `notPrepared`, idempotently.
struct DebugSeedingTests {
    @Test func seedsOne404ProjectIdempotently() async throws {
        let db = try AppDatabase.inMemory()
        let projects = ProjectRepository(dbWriter: db.writer)
        let packages = PackageRepository(dbWriter: db.writer, clock: TestClock())

        try await projects.seed404Project()
        try await projects.seed404Project() // second call must not duplicate

        let all = try await projects.fetchAll()
        #expect(all.count == 4) // three seeded + one demo failure
        let seeded = try #require(all.first { $0.id == "debug-fail-not-found" })
        #expect(seeded.packageURL.hasSuffix("sample-4.tar.gz"))
        #expect(seeded.sortOrder > 2) // sorts after the real projects

        // The demo project has a matching package row, ready for the engine to fail on.
        let record = try #require(try await packages.fetch(projectID: "debug-fail-not-found"))
        #expect(record.state == .notPrepared)
    }
}
