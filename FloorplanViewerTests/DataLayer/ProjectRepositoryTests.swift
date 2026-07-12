import Foundation
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

    @Test func projectListCarriesMarkerCountAndPreviewPath() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock(now: Date(timeIntervalSince1970: 5000))
        let projectRepo = ProjectRepository(dbWriter: db.writer)
        let packageRepo = PackageRepository(dbWriter: db.writer, clock: clock)
        let markerRepo = MarkerRepository(dbWriter: db.writer, clock: clock)

        try await packageRepo.markReady(projectID: "project-1", layout: ReadyPackage(
            projectID: "project-1",
            extractedRelDir: "extracted/project-1",
            descriptorRelPath: "extracted/project-1/tileset/floorplan.dzi",
            tilesRelDir: "extracted/project-1/tileset/tiles",
            width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
        ))
        try await markerRepo.insert(projectID: "project-1", normalizedX: 0.25, normalizedY: 0.5)
        try await markerRepo.insert(projectID: "project-1", normalizedX: 0.75, normalizedY: 0.5)

        let rows = try await projectRepo.fetchProjectList()
        let ready = try #require(rows.first { $0.id == "project-1" })
        #expect(ready.markerCount == 2)
        #expect(ready.extractedRelDir == "extracted/project-1")
        #expect(ready.previewRelPath == "extracted/project-1/preview.jpg")
        #expect(ready.lastSuccessAt == 5000)

        // A never-prepared row: no extracted dir → no preview path, and a zero marker count.
        let untouched = try #require(rows.first { $0.id == "project-2" })
        #expect(untouched.markerCount == 0)
        #expect(untouched.previewRelPath == nil)
        #expect(untouched.lastSuccessAt == nil)
    }

    @Test func observeProjectListRefreshesOnMarkerChanges() async throws {
        let db = try AppDatabase.inMemory()
        let projectRepo = ProjectRepository(dbWriter: db.writer)
        let markerRepo = MarkerRepository(dbWriter: db.writer, clock: TestClock())

        var iterator = projectRepo.observeProjectList().makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial?.first?.markerCount == 0)

        // The marker table is part of the observed region: insert and delete both emit.
        let marker = try await markerRepo.insert(projectID: "project-1", normalizedX: 0.5, normalizedY: 0.5)
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.first(where: { $0.id == "project-1" })?.markerCount == 1)

        try await markerRepo.delete(id: marker.id)
        let afterDelete = try await iterator.next()
        #expect(afterDelete?.first(where: { $0.id == "project-1" })?.markerCount == 0)
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
