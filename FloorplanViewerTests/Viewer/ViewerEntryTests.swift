import Foundation
import Testing
@testable import FloorplanViewer

/// The awaited viewer-entry handshake: `packageForViewing` settles verify-or-repair before
/// returning, so the viewer can never open stale paths.
struct ViewerEntryTests {
    private actor DemotingPreparation: PreparationTriggering {
        let packages: PackageRepository

        init(packages: PackageRepository) {
            self.packages = packages
        }

        func prepare(projectID _: String) async {}
        func retryNow(projectID _: String) async {}
        func prepareAll() async {}

        func packageForViewing(projectID: String) async throws -> ReadyPackage? {
            try await packages.markQueued(projectID: projectID)
            return nil
        }
    }

    @Test func brokenReadyRowIsRepairedBeforeThePackageIsReturned() async throws {
        let db = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "entry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackageStorage(root: root)
        let clock = TestClock()
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        let coordinator = PackagePreparationCoordinator(
            packages: packages,
            projects: ProjectRepository(dbWriter: db.writer),
            storage: storage,
            downloader: MockDownloader(),
            extractor: MockExtractor(),
            validator: MockValidator(),
            pathMonitor: StubPathMonitor(satisfied: true),
            clock: clock,
            rng: FixedRNG()
        )

        // A ready row whose files were deleted on disk (extracted tree AND archive gone).
        let archiveRel = storage.archiveRelPath(projectID: "project-1")
        try await packages.markDownloaded(projectID: "project-1", archiveRelPath: archiveRel)
        let extractedRel = storage.extractedRelDir(projectID: "project-1")
        try await packages.markReady(projectID: "project-1", layout: ReadyPackage(
            projectID: "project-1",
            extractedRelDir: extractedRel,
            descriptorRelPath: "\(extractedRel)/tileset/floorplan.dzi",
            tilesRelDir: "\(extractedRel)/tileset/tiles",
            width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
        ))

        // The handshake must not return until the repair pipeline (re-download via mocks,
        // re-extract, re-validate, promote) has settled — and then return a VALID package.
        let package = try await coordinator.packageForViewing(projectID: "project-1")
        let ready = try #require(package)
        #expect(storage.fileExists(atRelative: ready.descriptorRelPath))
        #expect(storage.fileExists(atRelative: "\(ready.tilesRelDir)/4/0_0.jpg"))
        #expect(try await packages.fetch(projectID: "project-1")?.state == .ready)
        await coordinator.stop()
    }

    @Test func neverPreparedOfflineReturnsNilNotStalePaths() async throws {
        let db = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "entry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        let coordinator = PackagePreparationCoordinator(
            packages: packages,
            projects: ProjectRepository(dbWriter: db.writer),
            storage: PackageStorage(root: root),
            downloader: MockDownloader(),
            extractor: MockExtractor(),
            validator: MockValidator(),
            pathMonitor: StubPathMonitor(satisfied: false), // offline
            clock: clock,
            rng: FixedRNG()
        )
        let package = try await coordinator.packageForViewing(projectID: "project-1")
        #expect(package == nil)
        #expect(try await packages.fetch(projectID: "project-1")?.state == .queued)
        await coordinator.stop()
    }

    @MainActor
    @Test func demotionDuringViewerHandshakeReachesTheUIInsteadOfSpinningOnReady() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        let layout = ReadyPackage(
            projectID: "project-1",
            extractedRelDir: "extracted/project-1",
            descriptorRelPath: "extracted/project-1/floorplan.dzi",
            tilesRelDir: "extracted/project-1/tiles",
            width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
        )
        try await packages.markReady(projectID: "project-1", layout: layout)

        let model = ViewerViewModel(
            projectID: "project-1",
            packages: packages,
            markerRepository: MarkerRepository(dbWriter: db.writer, clock: clock),
            preparation: DemotingPreparation(packages: packages),
            connectivity: ConnectivityState(monitor: StubPathMonitor(satisfied: true)),
            storage: PackageStorage(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        )
        let observation = Task { await model.observePackage() }
        defer { observation.cancel() }

        let consumedDemotion = await eventually { model.record?.state == .queued }
        #expect(consumedDemotion)
        #expect(model.content == nil)
    }
}
