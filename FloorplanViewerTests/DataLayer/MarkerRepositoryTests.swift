import GRDB
import Testing
@testable import FloorplanViewer

struct MarkerRepositoryTests {
    private func makeRepo() throws -> (MarkerRepository, AppDatabase, TestClock) {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        return (MarkerRepository(dbWriter: db.writer, clock: clock), db, clock)
    }

    @Test func insertRoundTripsThroughFreshFetch() async throws {
        let (repo, db, _) = try makeRepo()
        let inserted = try await repo.insert(projectID: "project-1", normalizedX: 0.25, normalizedY: 0.7)
        // A fresh repository over the same store reads it back — proves durability, not a cache.
        let reloaded = MarkerRepository(dbWriter: db.writer, clock: TestClock())
        let all = try await reloaded.fetchAll(projectID: "project-1")
        #expect(all.count == 1)
        #expect(all.first?.id == inserted.id)
        #expect(all.first?.normalizedX == 0.25)
        #expect(all.first?.normalizedY == 0.7)
    }

    @Test func insertClampsOutOfRangeCoordinates() async throws {
        let (repo, _, _) = try makeRepo()
        let marker = try await repo.insert(projectID: "project-1", normalizedX: 1.5, normalizedY: -0.3)
        #expect(marker.normalizedX == 1.0)
        #expect(marker.normalizedY == 0.0)
    }

    @Test func markersAreIsolatedPerProject() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.insert(projectID: "project-1", normalizedX: 0.1, normalizedY: 0.1)
        try await repo.insert(projectID: "project-2", normalizedX: 0.2, normalizedY: 0.2)
        #expect(try await repo.fetchAll(projectID: "project-1").count == 1)
        #expect(try await repo.fetchAll(projectID: "project-2").count == 1)
    }

    @Test func fetchAllIsOrderedByCreation() async throws {
        let (repo, _, clock) = try makeRepo()
        try await repo.insert(projectID: "project-1", normalizedX: 0.1, normalizedY: 0.1)
        clock.advance(by: 10)
        let second = try await repo.insert(projectID: "project-1", normalizedX: 0.2, normalizedY: 0.2)
        let all = try await repo.fetchAll(projectID: "project-1")
        #expect(all.last?.id == second.id)
    }

    @Test func deleteRemovesOnlyTheMarker() async throws {
        let (repo, _, _) = try makeRepo()
        let a = try await repo.insert(projectID: "project-1", normalizedX: 0.1, normalizedY: 0.1)
        try await repo.insert(projectID: "project-1", normalizedX: 0.2, normalizedY: 0.2)
        try await repo.delete(id: a.id)
        let all = try await repo.fetchAll(projectID: "project-1")
        #expect(all.count == 1)
        #expect(all.first?.id != a.id)
    }

    @Test func markersCascadeDeleteWithProject() async throws {
        let (repo, db, _) = try makeRepo()
        try await repo.insert(projectID: "project-1", normalizedX: 0.1, normalizedY: 0.1)
        try await db.writer.write { db in _ = try Project.deleteOne(db, key: "project-1") }
        #expect(try await repo.fetchAll(projectID: "project-1").isEmpty)
    }
}
