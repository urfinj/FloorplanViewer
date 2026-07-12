import Foundation
import Testing
@testable import FloorplanViewer

struct PackageRepositoryTests {
    private func makeRepo(now: Double = 5000) throws -> (PackageRepository, AppDatabase, TestClock) {
        let db = try AppDatabase.inMemory()
        let clock = TestClock(now: Date(timeIntervalSince1970: now))
        return (PackageRepository(dbWriter: db.writer, clock: clock), db, clock)
    }

    private func sampleLayout(_ id: String = "project-1") -> ReadyPackage {
        ReadyPackage(
            projectID: id,
            extractedRelDir: "extracted/\(id)",
            descriptorRelPath: "extracted/\(id)/tileset/floorplan.dzi",
            tilesRelDir: "extracted/\(id)/tileset/tiles",
            width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
        )
    }

    @Test func beginDownloadingSetsStateProgressAndAttempt() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.beginDownloading(projectID: "project-1")
        let rec = try await repo.fetch(projectID: "project-1")
        #expect(rec?.state == .downloading)
        #expect(rec?.downloadProgress == 0)
        #expect(rec?.lastAttemptAt == 5000)
        #expect(rec?.updatedAt == 5000)
    }

    @Test func setDownloadProgressIsNoOpWhenNotDownloading() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.markQueued(projectID: "project-1")
        try await repo.setDownloadProgress(projectID: "project-1", 0.4)
        #expect(try await repo.fetch(projectID: "project-1")?.downloadProgress == nil)
    }

    @Test func setDownloadProgressClampsAndWritesWhenDownloading() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.beginDownloading(projectID: "project-1")
        try await repo.setDownloadProgress(projectID: "project-1", 1.7)
        #expect(try await repo.fetch(projectID: "project-1")?.downloadProgress == 1.0)
    }

    @Test func markReadyWritesReadinessSetKeepsArchiveClearsFailure() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.markFailed(projectID: "project-1", reason: .network, retryCount: 3, nextRetryAt: 9000)
        try await repo.markDownloaded(projectID: "project-1", archiveRelPath: "archives/project-1.tar.gz")
        try await repo.beginExtracting(projectID: "project-1")
        try await repo.markReady(projectID: "project-1", layout: sampleLayout())
        let rec = try await repo.fetch(projectID: "project-1")
        #expect(rec?.state == .ready)
        #expect(rec?.archiveRelPath == "archives/project-1.tar.gz")
        #expect(rec?.dziWidth == 3300)
        #expect(rec?.dziMaxLevel == 4)
        #expect(rec?.descriptorRelPath == "extracted/project-1/tileset/floorplan.dzi")
        #expect(rec?.failureReasonRaw == nil)
        #expect(rec?.retryCount == 0)
        #expect(rec?.nextRetryAt == nil)
        #expect(rec?.lastSuccessAt == 5000)
    }

    @Test func markFailedRecordsReasonRetryAndClearsProgress() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.beginDownloading(projectID: "project-1")
        try await repo.markFailed(projectID: "project-1", reason: .httpStatus, retryCount: 2, nextRetryAt: 5100)
        let rec = try await repo.fetch(projectID: "project-1")
        #expect(rec?.state == .failed)
        #expect(rec?.failureReason == .httpStatus)
        #expect(rec?.retryCount == 2)
        #expect(rec?.nextRetryAt == 5100)
        #expect(rec?.downloadProgress == nil)
    }

    @Test func demoteClearsReadinessSetButKeepsArchiveWhenAsked() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.markDownloaded(projectID: "project-1", archiveRelPath: "archives/project-1.tar.gz")
        try await repo.markReady(projectID: "project-1", layout: sampleLayout())
        try await repo.demote(
            projectID: "project-1",
            to: .downloaded,
            clearingReadinessSet: true,
            clearingArchive: false
        )
        let rec = try await repo.fetch(projectID: "project-1")
        #expect(rec?.state == .downloaded)
        #expect(rec?.dziWidth == nil)
        #expect(rec?.descriptorRelPath == nil)
        #expect(rec?.archiveRelPath == "archives/project-1.tar.gz")
    }

    @Test(arguments: [
        "extracted_rel_dir",
        "descriptor_rel_path",
        "tiles_rel_dir",
        "dzi_width",
        "dzi_max_level",
        "dzi_format"
    ])
    func readyPackageIsAbsentWhenAnyReadinessColumnMissing(column: String) async throws {
        let (repo, db, _) = try makeRepo()
        try await repo.markReady(projectID: "project-1", layout: sampleLayout())
        #expect(try await repo.readyPackage(projectID: "project-1") != nil)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE package SET \(column) = NULL WHERE project_id = 'project-1'")
        }
        #expect(try await repo.readyPackage(projectID: "project-1") == nil)
    }

    @Test func clearNextRetryMakesRowDueKeepingHistory() async throws {
        let (repo, _, _) = try makeRepo()
        try await repo.markFailed(projectID: "project-1", reason: .network, retryCount: 3, nextRetryAt: 9999)
        try await repo.clearNextRetry(projectID: "project-1")
        let rec = try await repo.fetch(projectID: "project-1")
        #expect(rec?.nextRetryAt == nil)
        #expect(rec?.retryCount == 3)
        #expect(rec?.state == .failed)
    }
}
