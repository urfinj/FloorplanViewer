import Foundation
import os

/// The automatic preparation engine — the sole owner of package state transitions.
///
/// Invariants (see plan `00 §7/§9`):
/// - **Single-flight & reentrancy-proof:** the per-project task handle is registered before the
///   pipeline's first suspension; a repeated `prepare` while one is registered is a no-op.
/// - **Offline is not a failure:** the download gate parks work in `queued` without charging an
///   attempt or recording a reason; a downloaded archive still extracts offline.
/// - **Files first, then the DB write that references them;** extraction is validated in staging
///   and promoted atomically; a cancelled attempt records no outcome and resets to the nearest
///   safe checkpoint.
/// - Pipelines run under a concurrency cap so three simultaneous extractions can't spike.
actor PackagePreparationCoordinator {
    private let packages: PackageRepository
    private let projects: ProjectRepository
    private let storage: PackageStorage
    private let downloader: any PackageDownloading
    private let extractor: any ArchiveExtracting
    private let validator: any PackageValidating
    private let pathMonitor: any PathMonitoring
    private let clock: any AppClock
    private let backoff: BackoffPolicy
    private let pipelineLimiter: AsyncSemaphore
    private let maxAutoAttemptsPerSession: Int
    private var rng: any RandomNumberGenerator
    private let logger: Logger

    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Real failed attempts this session, per project — caps automatic retry so a permanent 404
    /// can't hot-loop. Launch (fresh map), connectivity, selection, and manual retry all reset it.
    private var sessionAttempts: [String: Int] = [:]
    /// Last persisted progress per project, for source-side write throttling.
    private var progressMarks: [String: (value: Double, at: Double)] = [:]
    private var retryTimer: Task<Void, Never>?
    private var isStopping = false
    /// `start()` is safe to call repeatedly (scene re-activation): the connectivity sink is
    /// registered exactly once — the production `NWPathMonitor` cannot restart after `cancel()`,
    /// and duplicate sinks would double-drain.
    private var monitorArmed = false

    #if DEBUG
        /// Test introspection.
        private(set) var progressWriteCount = 0
        var hasRetryTimer: Bool {
            retryTimer != nil
        }
    #endif

    init(
        packages: PackageRepository,
        projects: ProjectRepository,
        storage: PackageStorage,
        downloader: any PackageDownloading,
        extractor: any ArchiveExtracting,
        validator: any PackageValidating,
        pathMonitor: any PathMonitoring,
        clock: any AppClock,
        backoff: BackoffPolicy = BackoffPolicy(),
        pipelineLimiter: AsyncSemaphore = AsyncSemaphore(value: 2),
        maxAutoAttemptsPerSession: Int = 6,
        rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        logger: Logger = Log.prep
    ) {
        self.packages = packages
        self.projects = projects
        self.storage = storage
        self.downloader = downloader
        self.extractor = extractor
        self.validator = validator
        self.pathMonitor = pathMonitor
        self.clock = clock
        self.backoff = backoff
        self.pipelineLimiter = pipelineLimiter
        self.maxAutoAttemptsPerSession = maxAutoAttemptsPerSession
        self.rng = rng
        self.logger = logger
    }

    // MARK: - Lifecycle & triggers

    /// Arms the connectivity trigger (once) and drains everything. Idempotent — safe from the
    /// root scene task and scene re-activation alike.
    func start() async {
        isStopping = false
        if !monitorArmed {
            monitorArmed = true
            pathMonitor.start { [weak self] isSatisfied in
                guard isSatisfied else { return }
                Task { await self?.connectivityDidSatisfy() }
            }
        }
        await prepareAll()
    }

    /// Drains every project. Cheap when there is nothing to do: ready rows verify and no-op,
    /// in-flight rows are absorbed by single-flight.
    func prepareAll() async {
        guard !isStopping else { return }
        do {
            let all = try await projects.fetchAll()
            for project in all {
                prepare(projectID: project.id)
            }
        } catch {
            logger.error("prepareAll fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The sole idempotent entry point. Registers the task handle **before any suspension**, so
    /// actor reentrancy cannot double-start a project; repeated calls while in flight are no-ops.
    func prepare(projectID: String) {
        guard !isStopping, inFlight[projectID] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await runPipeline(projectID: projectID)
        }
        inFlight[projectID] = task
    }

    /// Manual retry: clears the persisted schedule and the session cap, then prepares.
    func retryNow(projectID: String) async {
        do {
            try await packages.resetRetrySchedule(projectID: projectID)
        } catch {
            logger.error("retryNow reset failed: \(String(describing: error), privacy: .public)")
        }
        sessionAttempts[projectID] = nil
        prepare(projectID: projectID)
    }

    /// A user selection is an explicit retry trigger: reset only the in-memory automatic-attempt
    /// cap, keep persisted retry history/backoff facts, and join the normal single-flight path.
    func projectSelected(projectID: String) {
        sessionAttempts[projectID] = nil
        prepare(projectID: projectID)
    }

    /// The viewer's entry hook: re-verify a `ready` row against disk; broken rows demote inside
    /// the pipeline and re-prepare automatically. Delegates to `prepare` — same idempotent path.
    func revalidateReady(projectID: String) {
        prepare(projectID: projectID)
    }

    /// The **awaited** viewer-entry handshake: run (or join) the verify-or-repair pipeline for
    /// this project, wait for it to settle, then read the validated `ReadyPackage`. The viewer
    /// consumes only this — never paths from an unverified row — so it can never open stale
    /// files that revalidation is about to demote.
    func packageForViewing(projectID: String) async throws -> ReadyPackage? {
        logger.notice("Viewer handshake: joining pipeline for \(projectID, privacy: .public)")
        prepare(projectID: projectID) // no-ops into the existing task when one is in flight
        if let task = inFlight[projectID] {
            await task.value
        }
        let package = try await packages.readyPackage(projectID: projectID)
        logger.notice("""
        Viewer handshake settled for \(projectID, privacy: .public): \
        \(package == nil ? "nil" : "ready", privacy: .public)
        """)
        return package
    }

    /// Connectivity restored: parked and failed rows become due immediately; session caps reset.
    func connectivityDidSatisfy() async {
        guard !isStopping else { return }
        sessionAttempts.removeAll()
        do {
            for record in try await packages.fetchAll() where record.state == .failed {
                try await packages.clearNextRetry(projectID: record.projectID)
            }
        } catch {
            logger.error("connectivity clear failed: \(String(describing: error), privacy: .public)")
        }
        await prepareAll()
    }

    /// Cancels and joins all in-flight work. Test seam (and future scene teardown).
    func stop() async {
        isStopping = true
        pathMonitor.cancel()
        retryTimer?.cancel()
        retryTimer = nil
        while !inFlight.isEmpty {
            let running = inFlight
            for task in running.values {
                task.cancel()
            }
            for task in running.values {
                await task.value
            }
        }
    }

    #if DEBUG
        /// Test seam: await all in-flight pipelines (loops — a settling pipeline can arm more work).
        func awaitQuiescence() async {
            while !inFlight.isEmpty {
                for task in inFlight.values {
                    await task.value
                }
            }
        }
    #endif

    // MARK: - Pipeline

    private func runPipeline(projectID: String) async {
        do {
            try await pipelineLimiter.withToken {
                await self.attempt(projectID: projectID)
            }
        } catch {
            // Only the limiter's wait can throw (cancellation while queued): nothing was started,
            // nothing to persist.
        }
        inFlight[projectID] = nil
        progressMarks[projectID] = nil
        if !isStopping {
            await armRetryTimer()
        }
    }

    private func attempt(projectID: String) async {
        do {
            try await runSteps(projectID: projectID)
        } catch {
            // Law: classify cancellation FIRST, never by error type alone.
            if error is CancellationError || Task.isCancelled {
                await handleCancellation(projectID: projectID)
            } else {
                await handleFailure(projectID: projectID, error: error)
            }
        }
    }

    private func runSteps(projectID: String) async throws {
        guard var record = try await packages.fetch(projectID: projectID) else { return }

        // Step 1: a ready row is verified against disk — never blindly trusted.
        if record.state == .ready {
            if PackageReadiness.filesPresent(for: record, storage: storage) {
                return // verified no-op (the assignment's "preparing a ready package is a no-op")
            }
            let archivePresent = record.archiveRelPath.map { storage.fileExists(atRelative: $0) } ?? false
            logger.notice("Ready row broken on disk; demoting \(projectID, privacy: .public)")
            try await packages.demote(
                projectID: projectID,
                to: archivePresent ? .downloaded : .queued,
                clearingReadinessSet: true,
                clearingArchive: !archivePresent
            )
            guard let refreshed = try await packages.fetch(projectID: projectID) else { return }
            record = refreshed
        }

        // Step 2/3: ensure the archive exists (download step; the only network-gated step).
        let archiveRel = storage.archiveRelPath(projectID: projectID)
        let archivePresent = record.archiveRelPath.map { storage.fileExists(atRelative: $0) } ?? false
        if !archivePresent {
            guard pathMonitor.isSatisfied else {
                // Offline: park without charging an attempt or recording a failure. A failed row
                // keeps its failure facts; anything else becomes/stays `queued`.
                if record.state != .failed {
                    try await packages.markQueued(projectID: projectID)
                }
                logger.notice("Offline — parked \(projectID, privacy: .public)")
                return
            }
            guard let project = try await projects.fetch(id: projectID),
                  let url = URL(string: project.packageURL)
            else {
                throw PreparationError(reason: .unknown)
            }
            try await packages.beginDownloading(projectID: projectID)
            let stagedArchive = storage.stagingURL().appending(path: "\(projectID).tar.gz")
            try? FileManager.default.removeItem(at: stagedArchive) // stale partial from a prior run
            logger.notice("Downloading \(projectID, privacy: .public)")
            try await downloader.download(from: url, to: stagedArchive) { [weak self] fraction in
                guard let self else { return }
                if let fraction {
                    await recordProgress(projectID: projectID, fraction: fraction)
                } else {
                    // Unknown total length: clear the 0% determinate bar so the UI shows an
                    // indeterminate spinner instead of a frozen bar (downloader sends nil once).
                    await recordIndeterminateProgress(projectID: projectID)
                }
            }
            try storage.promoteStagedFile(from: stagedArchive, toRelative: archiveRel)
            try await packages.markDownloaded(projectID: projectID, archiveRelPath: archiveRel)
        }

        // Step 4: extract into fresh staging (runs offline — no network gate here).
        try await packages.beginExtracting(projectID: projectID)
        let stagingDir = storage.freshStagingURL(component: "extract-\(projectID)")
        try? FileManager.default.removeItem(at: stagingDir)
        guard let archiveURL = storage.absoluteURL(for: archiveRel) else {
            throw PreparationError(reason: .unknown)
        }
        logger.notice("Extracting \(projectID, privacy: .public)")
        try await extractor.extract(archiveURL: archiveURL, into: stagingDir)

        // Step 5: validate in staging — never promote an unvalidated tree.
        let layout = try await validator.validate(extractedDir: stagingDir)

        // Step 6: promote, then the single DB write that references the promoted files.
        let extractedRel = storage.extractedRelDir(projectID: projectID)
        try storage.promoteStagedDirectory(from: stagingDir, toRelative: extractedRel)
        let ready = ReadyPackage(
            projectID: projectID,
            extractedRelDir: extractedRel,
            descriptorRelPath: "\(extractedRel)/\(layout.descriptorRelPath)",
            tilesRelDir: "\(extractedRel)/\(layout.tilesRelDir)",
            width: layout.width,
            height: layout.height,
            tileSize: layout.tileSize,
            overlap: layout.overlap,
            format: layout.format,
            maxFolderLevel: layout.maxFolderLevel
        )
        try await packages.markReady(projectID: projectID, layout: ready)
        sessionAttempts[projectID] = nil
        logger.notice("Ready: \(projectID, privacy: .public)")
    }

    // MARK: - Outcome handling

    private func handleFailure(projectID: String, error: any Error) async {
        let failure = PreparationError.classify(error)
        cleanStagingArtifacts(projectID: projectID)

        if failure.wentOffline, !pathMonitor.isSatisfied {
            // The network went away mid-step AND the monitor agrees: park, uncharged —
            // connectivity is the wake-up. If the path claims to be up (transient blip, captive
            // portal), fall through to the normal backoff below so a wake-up always exists.
            logger.notice("Went offline — parked \(projectID, privacy: .public)")
            await shielded { [packages] in
                try await packages.markQueued(projectID: projectID)
            }
            return
        }

        sessionAttempts[projectID, default: 0] += 1
        // A failed read must not silently reset persisted retry history: fall back to this
        // session's attempt count (≥ 1 here) so the backoff keeps growing.
        let previous: Int
        do {
            previous = try await packages.fetch(projectID: projectID)?.retryCount ?? 0
        } catch {
            logger.error("Reading retry history failed: \(String(describing: error), privacy: .public)")
            previous = sessionAttempts[projectID, default: 1] - 1
        }
        let retryCount = previous + 1
        // When the session cap is reached, persist NO schedule — the UI must not promise a retry
        // the cap will suppress. Launch, selection, connectivity, and manual retry still reset it.
        let capped = sessionAttempts[projectID, default: 0] >= maxAutoAttemptsPerSession
        let delay = backoff.delay(attempt: retryCount, unitJitter: nextUnitJitter())
        let nextRetryAt = capped ? nil : clock.now.timeIntervalSince1970 + delay
        logger.error("""
        Prepare failed for \(projectID, privacy: .public): \(failure.reason.rawValue, privacy: .public) \
        (attempt \(retryCount), \(
            capped ? "auto-retry capped this session" : "retry in \(Int(delay))s",
            privacy: .public
        ))
        """)

        var clearingArchive = false
        if failure.reason == .corruptArchive {
            // The archive itself is bad — drop it so the retry re-downloads.
            try? storage.removeItem(atRelative: storage.archiveRelPath(projectID: projectID))
            clearingArchive = true
        }
        let clear = clearingArchive
        await shielded { [packages] in
            try await packages.markFailed(
                projectID: projectID,
                reason: failure.reason,
                retryCount: retryCount,
                nextRetryAt: nextRetryAt,
                clearingArchive: clear
            )
        }
    }

    /// Cancellation records no outcome: reset to the nearest safe checkpoint and clean this
    /// attempt's staging artifacts. The write is shielded — GRDB async accesses honor task
    /// cancellation, and this write must land from a cancelled task.
    private func handleCancellation(projectID: String) async {
        cleanStagingArtifacts(projectID: projectID)
        let archivePresent = storage.fileExists(atRelative: storage.archiveRelPath(projectID: projectID))
        logger.notice("Cancelled — resetting \(projectID, privacy: .public)")
        await shielded { [packages] in
            guard let record = try await packages.fetch(projectID: projectID),
                  record.state == .downloading || record.state == .extracting
            else { return }
            try await packages.demote(
                projectID: projectID,
                to: archivePresent ? .downloaded : .queued,
                clearingReadinessSet: false,
                clearingArchive: false
            )
        }
    }

    private func cleanStagingArtifacts(projectID: String) {
        try? FileManager.default.removeItem(at: storage.stagingURL().appending(path: "\(projectID).tar.gz"))
        try? FileManager.default.removeItem(at: storage.freshStagingURL(component: "extract-\(projectID)"))
    }

    /// Runs a persistence closure outside the current task's cancellation scope.
    private func shielded(_ body: @escaping @Sendable () async throws -> Void) async {
        let logger = logger
        await Task {
            do {
                try await body()
            } catch {
                logger.error("Shielded write failed: \(String(describing: error), privacy: .public)")
            }
        }.value
    }

    // MARK: - Progress (source-side throttle: ≥5% delta or ≥500ms; 1.0 always lands)

    private func recordProgress(projectID: String, fraction: Double) async {
        let now = clock.now.timeIntervalSince1970
        let mark = progressMarks[projectID]
        let isFinal = fraction >= 1.0
        guard mark == nil || fraction > (mark?.value ?? 0) else { return } // monotonic only
        if let mark, !isFinal, fraction - mark.value < 0.05, now - mark.at < 0.5 {
            return
        }
        progressMarks[projectID] = (fraction, now)
        #if DEBUG
            progressWriteCount += 1
        #endif
        do {
            try await packages.setDownloadProgress(projectID: projectID, fraction)
        } catch {
            logger.error("Progress write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func recordIndeterminateProgress(projectID: String) async {
        do {
            try await packages.setDownloadProgress(projectID: projectID, nil)
        } catch {
            logger.error("Progress clear failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Retry timer (one coalesced timer for the soonest due failed row)

    private func armRetryTimer() async {
        retryTimer?.cancel()
        retryTimer = nil
        guard !isStopping else { return }
        // A failed read is not evidence that nothing is owed: keep the retry driver armed with a
        // fixed store-recovery delay instead of silently going dark.
        let records: [PackageRecord]
        do {
            records = try await packages.fetchAll()
        } catch {
            logger.error("Retry-timer query failed: \(String(describing: error), privacy: .public)")
            scheduleTimer(after: 5)
            return
        }
        let eligible = records.filter { record in
            record.state == .failed
                && record.nextRetryAt != nil
                && sessionAttempts[record.projectID, default: 0] < maxAutoAttemptsPerSession
                && isActionableNow(record)
        }
        guard let soonest = eligible.compactMap(\.nextRetryAt).min() else { return }
        scheduleTimer(after: max(0, soonest - clock.now.timeIntervalSince1970))
    }

    /// Whether a retry could make progress right now. While offline, a row with no local archive
    /// would just bounce off the download gate uncharged — arming/draining for it produces a
    /// zero-delay hot loop. Offline rows with an archive still extract; connectivity restoration
    /// (`connectivityDidSatisfy`) is the wake-up for everything else.
    private func isActionableNow(_ record: PackageRecord) -> Bool {
        pathMonitor.isSatisfied || (record.archiveRelPath.map { storage.fileExists(atRelative: $0) } ?? false)
    }

    private func scheduleTimer(after delay: TimeInterval) {
        // Restore the single-timer invariant on every interleaving, and never arm past `stop()`.
        retryTimer?.cancel()
        guard !isStopping else {
            retryTimer = nil
            return
        }
        retryTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // cancelled — do not drain
            }
            await self?.drainDue()
        }
    }

    /// Timer drain: **due failed rows only**. Queued/notPrepared rows are driven by the explicit
    /// triggers (launch, selection, connectivity, foreground) — a project's retry timer must not
    /// opportunistically start unrelated work.
    private func drainDue() async {
        guard !isStopping else { return }
        // We ARE the fired timer: drop the handle without cancelling. If the tail re-arms via
        // `armRetryTimer`, its `retryTimer?.cancel()` must not cancel *this* task — a cancelled
        // task's GRDB reads throw and would silently kill the re-arm chain.
        retryTimer = nil
        let now = clock.now.timeIntervalSince1970
        let records: [PackageRecord]
        do {
            records = try await packages.fetchAll()
        } catch {
            // Same rule as arming: a failed read keeps the driver alive rather than going dark.
            logger.error("Timer drain query failed: \(String(describing: error), privacy: .public)")
            scheduleTimer(after: 5)
            return
        }
        let due = records.filter { record in
            record.state == .failed
                && (record.nextRetryAt ?? 0) <= now
                && sessionAttempts[record.projectID, default: 0] < maxAutoAttemptsPerSession
                && isActionableNow(record)
        }
        for record in due {
            prepare(projectID: record.projectID)
        }
        if inFlight.isEmpty {
            await armRetryTimer()
        }
    }

    private func nextUnitJitter() -> Double {
        Double(rng.next()) / Double(UInt64.max)
    }
}
