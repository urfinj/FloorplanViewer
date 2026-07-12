import Testing
@testable import FloorplanViewer

struct ProjectRepositoryTests {
    @Test func fetchProjectListJoinsPackageState() async throws {
        let db = try AppDatabase.inMemory()
        let repo = ProjectRepository(dbWriter: db.writer)
        let rows = try await repo.fetchProjectList()
        #expect(rows.count == 3)
        #expect(rows.map(\.id) == ["project-1", "project-2", "project-3"])
        #expect(rows.allSatisfy { $0.state == .notPrepared })
    }

    @Test func observeProjectListEmitsInitialThenOnChange() async throws {
        let db = try AppDatabase.inMemory()
        let projectRepo = ProjectRepository(dbWriter: db.writer)
        let packageRepo = PackageRepository(dbWriter: db.writer, clock: TestClock())

        var iterator = projectRepo.observeProjectList().makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.count == 3)
        #expect(first?.first?.state == .notPrepared)

        try await packageRepo.beginDownloading(projectID: "project-1")
        let second = try await iterator.next()
        #expect(second?.first(where: { $0.id == "project-1" })?.state == .downloading)
    }
}
