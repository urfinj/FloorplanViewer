import Foundation
import Testing
@testable import FloorplanViewer

/// The recovery matrix: every persisted state × disk-artifact combination normalizes to the
/// nearest safe checkpoint; staging is wiped; orphans are swept; markers survive everything.
struct LaunchRecoveryTests {
    struct Harness {
        let db: AppDatabase
        let root: URL
        let storage: PackageStorage
        let packages: PackageRepository
        let markers: MarkerRepository
        let recovery: LaunchRecovery

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        func writeArchive(_ projectID: String) throws -> String {
            let rel = storage.archiveRelPath(projectID: projectID)
            let url = try #require(storage.absoluteURL(for: rel))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 1, count: 32).write(to: url)
            return rel
        }

        func materializeReady(_ projectID: String) async throws {
            let archiveRel = try writeArchive(projectID)
            try await packages.markDownloaded(projectID: projectID, archiveRelPath: archiveRel)
            let extractedRel = storage.extractedRelDir(projectID: projectID)
            let extractedURL = try #require(storage.absoluteURL(for: extractedRel))
            try MockExtractor.buildSampleTree(in: extractedURL)
            try await packages.markReady(projectID: projectID, layout: ReadyPackage(
                projectID: projectID,
                extractedRelDir: extractedRel,
                descriptorRelPath: "\(extractedRel)/tileset/floorplan.dzi",
                tilesRelDir: "\(extractedRel)/tileset/tiles",
                width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
            ))
        }

        func record(_ projectID: String) async throws -> PackageRecord {
            try #require(try await packages.fetch(projectID: projectID))
        }
    }

    private func makeHarness() throws -> Harness {
        let db = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = PackageStorage(root: root)
        let clock = TestClock()
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        return Harness(
            db: db, root: root, storage: storage, packages: packages,
            markers: MarkerRepository(dbWriter: db.writer, clock: clock),
            recovery: LaunchRecovery(packages: packages, storage: storage)
        )
    }

    // MARK: - Matrix

    @Test func interruptedDownloadingDemotesToQueued() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.packages.beginDownloading(projectID: "project-1") // no archive recorded yet
        try await h.recovery.recover()
        let rec = try await h.record("project-1")
        #expect(rec.state == .queued)
        #expect(rec.downloadProgress == nil)
    }

    @Test func interruptedExtractingWithArchiveDemotesToDownloaded() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        let archiveRel = try h.writeArchive("project-1")
        try await h.packages.markDownloaded(projectID: "project-1", archiveRelPath: archiveRel)
        try await h.packages.beginExtracting(projectID: "project-1")
        try await h.recovery.recover()
        let rec = try await h.record("project-1")
        #expect(rec.state == .downloaded)
        #expect(rec.archiveRelPath == archiveRel)
        #expect(h.storage.fileExists(atRelative: archiveRel)) // survived the orphan sweep
    }

    @Test func interruptedExtractingWithMissingArchiveDemotesToQueued() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.packages.markDownloaded(projectID: "project-1", archiveRelPath: "archives/project-1.tar.gz")
        try await h.packages.beginExtracting(projectID: "project-1") // file never written / deleted
        try await h.recovery.recover()
        let rec = try await h.record("project-1")
        #expect(rec.state == .queued)
        #expect(rec.archiveRelPath == nil)
    }

    @Test func downloadedWithMissingArchiveDemotesToQueued() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.packages.markDownloaded(projectID: "project-1", archiveRelPath: "archives/project-1.tar.gz")
        try await h.recovery.recover()
        #expect(try await h.record("project-1").state == .queued)
    }

    @Test func intactDownloadedAndReadyRowsAreUntouched() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        let archiveRel = try h.writeArchive("project-2")
        try await h.packages.markDownloaded(projectID: "project-2", archiveRelPath: archiveRel)
        try await h.materializeReady("project-1")
        let report = try await h.recovery.recover()
        #expect(try await h.record("project-1").state == .ready)
        #expect(try await h.record("project-2").state == .downloaded)
        #expect(report.normalizedProjects.isEmpty)
    }

    @Test func brokenReadyDemotesByArchivePresence() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        // project-1: broken ready, archive still on disk → downloaded.
        try await h.materializeReady("project-1")
        try h.storage.removeItem(atRelative: "extracted/project-1/tileset/floorplan.dzi")
        // project-2: broken ready, no archive → queued.
        try await h.materializeReady("project-2")
        try h.storage.removeItem(atRelative: h.storage.extractedRelDir(projectID: "project-2"))
        try h.storage.removeItem(atRelative: h.storage.archiveRelPath(projectID: "project-2"))

        try await h.recovery.recover()
        let first = try await h.record("project-1")
        #expect(first.state == .downloaded)
        #expect(first.descriptorRelPath == nil) // readiness set cleared
        #expect(try await h.record("project-2").state == .queued)
    }

    @Test func failedRowBecomesDueOnLaunch() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.packages.markFailed(projectID: "project-1", reason: .network, retryCount: 3, nextRetryAt: 99_999)
        try await h.recovery.recover()
        let rec = try await h.record("project-1")
        #expect(rec.state == .failed)
        #expect(rec.nextRetryAt == nil) // retry-on-launch
        #expect(rec.retryCount == 3) // history kept
    }

    // MARK: - Staging, orphans, markers

    @Test func stagingIsWipedAndOrphansSwept() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        // Staging junk.
        let staging = h.storage.freshStagingURL(component: "extract-project-1")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: h.storage.stagingURL().appending(path: "project-1.tar.gz"))
        // Orphan archive + extracted tree nothing references; plus a referenced archive that must stay.
        let keptRel = try h.writeArchive("project-2")
        try await h.packages.markDownloaded(projectID: "project-2", archiveRelPath: keptRel)
        _ = try h.writeArchive("project-3") // row still notPrepared → unreferenced → orphan
        let orphanTree = try #require(h.storage.absoluteURL(for: "extracted/ghost"))
        try MockExtractor.buildSampleTree(in: orphanTree)

        let report = try await h.recovery.recover()
        #expect(!FileManager.default.fileExists(atPath: h.storage.stagingURL().path))
        #expect(!h.storage.fileExists(atRelative: "archives/project-3.tar.gz"))
        #expect(!h.storage.directoryExists(atRelative: "extracted/ghost"))
        #expect(h.storage.fileExists(atRelative: keptRel))
        #expect(report.orphansRemoved.sorted() == ["archives/project-3.tar.gz", "extracted/ghost"])
    }

    @Test func markersSurviveEveryRecoveryPath() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.markers.insert(projectID: "project-1", normalizedX: 0.25, normalizedY: 0.75)
        // Worst case: broken ready with nothing on disk.
        try await h.materializeReady("project-1")
        try h.storage.removeItem(atRelative: h.storage.extractedRelDir(projectID: "project-1"))
        try h.storage.removeItem(atRelative: h.storage.archiveRelPath(projectID: "project-1"))

        try await h.recovery.recover()
        let markers = try await h.markers.fetchAll(projectID: "project-1")
        #expect(markers.count == 1)
        #expect(markers.first?.normalizedX == 0.25)
    }
}
