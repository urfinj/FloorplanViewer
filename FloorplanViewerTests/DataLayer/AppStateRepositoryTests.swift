import GRDB
import Testing
@testable import FloorplanViewer

struct AppStateRepositoryTests {
    private func makeRepo() throws -> (AppStateRepository, AppDatabase) {
        let db = try AppDatabase.inMemory()
        return (AppStateRepository(dbWriter: db.writer, clock: TestClock()), db)
    }

    @Test func selectionRoundTrips() async throws {
        let (repo, _) = try makeRepo()
        #expect(try await repo.lastSelectedProjectID() == nil)
        try await repo.setLastSelectedProjectID("project-2")
        #expect(try await repo.lastSelectedProjectID() == "project-2")
    }

    @Test func selectionNullsWhenProjectDeleted() async throws {
        let (repo, db) = try makeRepo()
        try await repo.setLastSelectedProjectID("project-1")
        try await db.writer.write { db in _ = try Project.deleteOne(db, key: "project-1") }
        #expect(try await repo.lastSelectedProjectID() == nil)
    }
}
