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

    @Test func catalogSyncRefreshesEndpointWithoutReplacingProjectState() async throws {
        let db = try AppDatabase.inMemory()
        let projectRepo = ProjectRepository(dbWriter: db.writer)
        let packageRepo = PackageRepository(dbWriter: db.writer, clock: TestClock())
        try await packageRepo.beginDownloading(projectID: "project-1")

        let updated = PackageCatalog.Spec(
            id: "project-1", name: "Updated Project", url: "https://example.invalid/floorplan.tar.gz"
        )
        try await projectRepo.synchronizeCatalog([updated])

        let project = try #require(try await projectRepo.fetch(id: "project-1"))
        #expect(project.name == "Updated Project")
        #expect(project.packageURL == updated.url)
        #expect(try await packageRepo.fetch(projectID: "project-1")?.state == .downloading)
    }
}
