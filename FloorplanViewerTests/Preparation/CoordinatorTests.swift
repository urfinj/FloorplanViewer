import Foundation
import Testing
@testable import FloorplanViewer

/// Everything the coordinator promises: idempotency, single-flight, resume-from-artifacts,
/// offline semantics, retry/backoff, cancellation, throttling, and the concurrency cap.
struct CoordinatorTests {
    // MARK: - Harness

    struct Harness {
        let db: AppDatabase
        let root: URL
        let storage: PackageStorage
        let clock: TestClock
        let packages: PackageRepository
        let downloader: MockDownloader
        let extractor: MockExtractor
        let validator: MockValidator
        let monitor: StubPathMonitor
        let coordinator: PackagePreparationCoordinator

        var now: Double {
            clock.now.timeIntervalSince1970
        }

        /// Seeds a fully ready package: archive + extracted tree on disk, readiness set in the DB.
        func materializeReady(_ projectID: String) async throws {
            let archiveRel = storage.archiveRelPath(projectID: projectID)
            let archiveURL = try #require(storage.absoluteURL(for: archiveRel))
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 1, count: 64).write(to: archiveURL)
            try await packages.markDownloaded(projectID: projectID, archiveRelPath: archiveRel)

            let extractedRel = storage.extractedRelDir(projectID: projectID)
            let extractedURL = try #require(storage.absoluteURL(for: extractedRel))
            try MockExtractor.buildSampleTree(in: extractedURL)
            try await packages.markReady(projectID: projectID, layout: readyLayout(projectID))
        }

        func readyLayout(_ projectID: String) -> ReadyPackage {
            let extractedRel = storage.extractedRelDir(projectID: projectID)
            return ReadyPackage(
                projectID: projectID,
                extractedRelDir: extractedRel,
                descriptorRelPath: "\(extractedRel)/tileset/floorplan.dzi",
                tilesRelDir: "\(extractedRel)/tileset/tiles",
                width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
            )
        }

        func record(_ projectID: String) async throws -> PackageRecord {
            try #require(try await packages.fetch(projectID: projectID))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeHarness(
        downloader: MockDownloader = MockDownloader(),
        extractor: MockExtractor = MockExtractor(),
        validator: MockValidator = MockValidator(),
        satisfied: Bool = true,
        backoff: BackoffPolicy = BackoffPolicy(),
        pipelineLimit: Int = 2,
        maxAutoAttempts: Int = 6
    ) throws -> Harness {
        let db = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = PackageStorage(root: root)
        let clock = TestClock(now: Date(timeIntervalSince1970: 10_000))
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        let monitor = StubPathMonitor(satisfied: satisfied)
        let coordinator = PackagePreparationCoordinator(
            packages: packages,
            projects: ProjectRepository(dbWriter: db.writer),
            storage: storage,
            downloader: downloader,
            extractor: extractor,
            validator: validator,
            pathMonitor: monitor,
            clock: clock,
            backoff: backoff,
            pipelineLimiter: AsyncSemaphore(value: pipelineLimit),
            maxAutoAttemptsPerSession: maxAutoAttempts,
            rng: FixedRNG()
        )
        return Harness(
            db: db, root: root, storage: storage, clock: clock, packages: packages,
            downloader: downloader, extractor: extractor, validator: validator,
            monitor: monitor, coordinator: coordinator
        )
    }

    // MARK: - Happy path & idempotency

    @Test func happyPathWalksToReadyWithArtifactsAndReadinessSet() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        let rec = try await h.record("project-1")
        #expect(rec.state == .ready)
        #expect(rec.dziWidth == 3300)
        #expect(rec.dziMaxLevel == 4)
        #expect(rec.lastSuccessAt == h.now)
        #expect(rec.downloadProgress == nil)
        #expect(h.storage.fileExists(atRelative: "archives/project-1.tar.gz"))
        #expect(h.storage.fileExists(atRelative: "extracted/project-1/tileset/floorplan.dzi"))
        #expect(h.storage.fileExists(atRelative: "extracted/project-1/tileset/tiles/4/0_0.jpg"))
        #expect(try await h.packages.readyPackage(projectID: "project-1") != nil)
        await h.coordinator.stop()
    }

    @Test func repeatedPrepareWhileInFlightStartsExactlyOneDownload() async throws {
        let downloader = MockDownloader(script: [.hangUntilCancelled])
        let h = try makeHarness(downloader: downloader)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.prepare(projectID: "project-1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(downloader.calls == 1)
        await h.coordinator.stop()
        #expect(downloader.calls == 1)
    }

    @Test func prepareOnVerifiedReadyIsNoOp() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.materializeReady("project-1")
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(h.downloader.calls == 0)
        #expect(h.extractor.calls == 0)
        #expect(try await h.record("project-1").state == .ready)
        await h.coordinator.stop()
    }

    @Test func downloadedArchiveSkipsDownloadAndExtracts() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        let archiveRel = h.storage.archiveRelPath(projectID: "project-1")
        let archiveURL = try #require(h.storage.absoluteURL(for: archiveRel))
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 64).write(to: archiveURL)
        try await h.packages.markDownloaded(projectID: "project-1", archiveRelPath: archiveRel)

        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(h.downloader.calls == 0)
        #expect(h.extractor.calls == 1)
        #expect(try await h.record("project-1").state == .ready)
        await h.coordinator.stop()
    }

    // MARK: - Ready-but-broken recovery ("never blindly trust the database")

    @Test func brokenReadyWithArchiveReExtractsWithoutDownloading() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.materializeReady("project-1")
        try h.storage.removeItem(atRelative: h.storage.extractedRelDir(projectID: "project-1"))

        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(h.downloader.calls == 0)
        #expect(h.extractor.calls == 1)
        #expect(try await h.record("project-1").state == .ready)
        await h.coordinator.stop()
    }

    @Test func brokenReadyWithoutArchiveRedownloads() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }
        try await h.materializeReady("project-1")
        try h.storage.removeItem(atRelative: h.storage.extractedRelDir(projectID: "project-1"))
        try h.storage.removeItem(atRelative: h.storage.archiveRelPath(projectID: "project-1"))

        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(h.downloader.calls == 1)
        #expect(try await h.record("project-1").state == .ready)
        await h.coordinator.stop()
    }

    // MARK: - Failure, backoff & retry

    @Test func downloadFailureRecordsReasonAndExactBackoff() async throws {
        let downloader = MockDownloader(script: [.failure(PreparationError(reason: .httpStatus))])
        let h = try makeHarness(downloader: downloader)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        var rec = try await h.record("project-1")
        #expect(rec.state == .failed)
        #expect(rec.failureReason == .httpStatus)
        #expect(rec.retryCount == 1)
        #expect(rec.nextRetryAt == h.now + 1.5) // base 3, zero jitter → capped/2

        // A second explicit prepare (retry) increments the persisted count and doubles the delay.
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        rec = try await h.record("project-1")
        #expect(rec.retryCount == 2)
        #expect(rec.nextRetryAt == h.now + 3.0)
        await h.coordinator.stop()
    }

    @Test func validatorFailureNeverPromotesAndLandsFailed() async throws {
        let validator = MockValidator(script: [.failure(PreparationError(reason: .tilesMissing))])
        let h = try makeHarness(validator: validator)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        let rec = try await h.record("project-1")
        #expect(rec.state == .failed)
        #expect(rec.failureReason == .tilesMissing)
        #expect(!h.storage.directoryExists(atRelative: "extracted/project-1"))
        #expect(!FileManager.default.fileExists(atPath: h.storage.freshStagingURL(component: "extract-project-1").path))
        await h.coordinator.stop()
    }

    @Test func corruptArchiveDeletesArchiveAndRetryRedownloads() async throws {
        let extractor = MockExtractor(script: [.failure(PreparationError(reason: .corruptArchive)), .success])
        let h = try makeHarness(extractor: extractor)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        var rec = try await h.record("project-1")
        #expect(rec.state == .failed)
        #expect(rec.failureReason == .corruptArchive)
        #expect(rec.archiveRelPath == nil)
        #expect(!h.storage.fileExists(atRelative: "archives/project-1.tar.gz"))

        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        rec = try await h.record("project-1")
        #expect(h.downloader.calls == 2) // re-downloaded after the archive was dropped
        #expect(rec.state == .ready)
        await h.coordinator.stop()
    }

    @Test func retryNowResetsScheduleAndRuns() async throws {
        let downloader = MockDownloader(script: [.failure(PreparationError(reason: .network)), .success()])
        let h = try makeHarness(downloader: downloader)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(try await h.record("project-1").state == .failed)

        await h.coordinator.retryNow(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        let rec = try await h.record("project-1")
        #expect(rec.state == .ready)
        #expect(rec.retryCount == 0)
        await h.coordinator.stop()
    }

    // MARK: - Offline semantics (offline is not a failure)

    @Test func offlineParksQueuedWithoutChargingAnything() async throws {
        let h = try makeHarness(satisfied: false)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        let rec = try await h.record("project-1")
        #expect(rec.state == .queued)
        #expect(rec.retryCount == 0)
        #expect(rec.failureReason == nil)
        #expect(h.downloader.calls == 0)
        await h.coordinator.stop()
    }

    @Test func offlineDueFailedRowDoesNotHotLoopTheRetryTimer() async throws {
        // Regression: a row fails online (past-due schedule), then the device goes offline with
        // no local archive. The timer must NOT arm (a drain would bounce off the offline gate
        // uncharged, re-arm at zero delay, and spin). Connectivity return is the wake-up.
        let h = try makeHarness(satisfied: false)
        defer { h.cleanUp() }
        await h.coordinator.start() // arms the connectivity sink; offline drain parks everything
        await h.coordinator.awaitQuiescence()
        try await h.packages.markFailed(
            projectID: "project-1", reason: .httpStatus, retryCount: 1, nextRetryAt: h.now - 10
        )
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(await h.coordinator.hasRetryTimer == false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.downloader.calls == 0) // no spin while offline

        h.monitor.set(satisfied: true) // restore → drains and succeeds
        let recovered = await eventually { await (try? h.record("project-1").state) == .ready }
        #expect(recovered)
        await h.coordinator.stop()
    }

    @Test func offlineKeepsFailedRowFactsIntact() async throws {
        let h = try makeHarness(satisfied: false)
        defer { h.cleanUp() }
        try await h.packages.markFailed(
            projectID: "project-1", reason: .network, retryCount: 2, nextRetryAt: h.now + 99
        )
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        let rec = try await h.record("project-1")
        #expect(rec.state == .failed)
        #expect(rec.failureReason == .network)
        #expect(rec.retryCount == 2)
        #expect(h.downloader.calls == 0)
        await h.coordinator.stop()
    }

    @Test func offlineWithArchiveStillExtractsToReady() async throws {
        let h = try makeHarness(satisfied: false)
        defer { h.cleanUp() }
        let archiveRel = h.storage.archiveRelPath(projectID: "project-1")
        let archiveURL = try #require(h.storage.absoluteURL(for: archiveRel))
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 64).write(to: archiveURL)
        try await h.packages.markDownloaded(projectID: "project-1", archiveRelPath: archiveRel)

        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(try await h.record("project-1").state == .ready) // download gate only
        #expect(h.downloader.calls == 0)
        await h.coordinator.stop()
    }

    @Test func connectivityReturnDrainsParkedRows() async throws {
        let h = try makeHarness(satisfied: false)
        defer { h.cleanUp() }
        await h.coordinator.start() // parks all three offline
        await h.coordinator.awaitQuiescence()
        #expect(try await h.record("project-1").state == .queued)

        h.monitor.set(satisfied: true) // NWPathMonitor-style callback → coordinator drains
        let allReady = await eventually {
            let first = try? await h.record("project-1").state
            let second = try? await h.record("project-2").state
            let third = try? await h.record("project-3").state
            return first == .ready && second == .ready && third == .ready
        }
        #expect(allReady)
        await h.coordinator.stop()
    }

    // MARK: - Cancellation

    @Test func stopMidDownloadResetsToQueuedUncharged() async throws {
        let downloader = MockDownloader(script: [.hangUntilCancelled])
        let h = try makeHarness(downloader: downloader)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        // Ensure the pipeline actually entered the download step before stopping.
        #expect(await eventually { await (try? h.record("project-1").state) == .downloading })
        await h.coordinator.stop()

        let rec = try await h.record("project-1")
        #expect(rec.state == .queued)
        #expect(rec.retryCount == 0)
        #expect(rec.failureReason == nil)
        #expect(!h.storage.fileExists(atRelative: "archives/project-1.tar.gz"))
    }

    @Test func stopMidExtractResetsToDownloadedKeepingArchive() async throws {
        let extractor = MockExtractor(script: [.hangUntilCancelled])
        let h = try makeHarness(extractor: extractor)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        // Ensure the pipeline downloaded and entered the extract step before stopping.
        #expect(await eventually { await (try? h.record("project-1").state) == .extracting })
        await h.coordinator.stop()

        let rec = try await h.record("project-1")
        #expect(rec.state == .downloaded)
        #expect(h.storage.fileExists(atRelative: "archives/project-1.tar.gz"))
        #expect(rec.failureReason == nil)
    }

    // MARK: - Throttling & concurrency cap

    @Test func progressWritesAreThrottledAtSource() async throws {
        let ticks = stride(from: 0.01, through: 1.0, by: 0.01).map(\.self)
        let downloader = MockDownloader(script: [.success(bytes: 64, ticks: ticks)])
        let h = try makeHarness(downloader: downloader)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()

        let writes = await h.coordinator.progressWriteCount
        #expect(writes >= 1)
        #expect(writes <= 25) // 100 raw ticks → ≤ ~21 persisted (5% delta gate)
        await h.coordinator.stop()
    }

    @Test func pipelineLimiterCapsConcurrentPreparations() async throws {
        let downloader = MockDownloader(script: [.hangUntilCancelled, .hangUntilCancelled, .hangUntilCancelled])
        let h = try makeHarness(downloader: downloader, pipelineLimit: 1)
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.prepare(projectID: "project-2")
        try await Task.sleep(for: .milliseconds(80))
        #expect(downloader.calls == 1) // second pipeline queued behind the semaphore
        await h.coordinator.stop()
    }

    @Test func sessionCapStopsAutoRetriesAndExplicitTriggersResetIt() async throws {
        // Failing downloader, tiny real backoff so the auto-retry timer actually fires.
        let downloader = MockDownloader(script: [.failure(PreparationError(reason: .network))])
        let h = try makeHarness(
            downloader: downloader,
            backoff: BackoffPolicy(base: 0.02, cap: 0.05),
            maxAutoAttempts: 2
        )
        defer { h.cleanUp() }
        await h.coordinator.prepare(projectID: "project-1")
        await h.coordinator.awaitQuiescence()
        #expect(await h.coordinator.hasRetryTimer) // armed for the due retry
        // The timer sleeps ~10ms of real time; advance the test clock past next_retry_at so the
        // fired drain sees the row as due, then wait for the second (capped-after) attempt.
        h.clock.advance(by: 1)
        #expect(await eventually { downloader.calls == 2 })
        await h.coordinator.awaitQuiescence()
        try await Task.sleep(for: .milliseconds(150))
        #expect(downloader.calls == 2) // cap 2: no third automatic attempt

        await h.coordinator.projectSelected(projectID: "project-1") // selection resets the session cap
        #expect(await eventually { downloader.calls == 3 })
        await h.coordinator.awaitQuiescence()

        await h.coordinator.retryNow(projectID: "project-1") // manual retry also resets it
        #expect(await eventually { downloader.calls == 4 })
        await h.coordinator.stop()
    }
}
