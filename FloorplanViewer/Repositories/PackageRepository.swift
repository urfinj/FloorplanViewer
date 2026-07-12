import Foundation
import GRDB

/// The package state-machine boundary. Every state transition is a single write that stamps
/// `updated_at`; the coordinator is the only caller of the transition methods. Narrow methods
/// (not a generic "save") centralize the field-clearing rules and prevent state regression.
nonisolated struct PackageRepository: Sendable {
    let dbWriter: any DatabaseWriter
    let clock: any AppClock

    // MARK: - Reads

    func fetch(projectID: String) async throws -> PackageRecord? {
        try await dbWriter.read { db in try PackageRecord.fetchOne(db, key: projectID) }
    }

    func fetchAll() async throws -> [PackageRecord] {
        try await dbWriter.read { db in
            try PackageRecord.order(PackageRecord.Columns.projectID).fetchAll(db)
        }
    }

    func observePackage(projectID: String) -> AsyncValueObservation<PackageRecord?> {
        ValueObservation
            .tracking { db in try PackageRecord.fetchOne(db, key: projectID) }
            .values(in: dbWriter)
    }

    /// Complete-or-absent: non-nil only when `ready` and every readiness column is present.
    func readyPackage(projectID: String) async throws -> ReadyPackage? {
        try await dbWriter.read { db in
            guard let rec = try PackageRecord.fetchOne(db, key: projectID), rec.state == .ready,
                  let extractedRelDir = rec.extractedRelDir,
                  let descriptorRelPath = rec.descriptorRelPath,
                  let tilesRelDir = rec.tilesRelDir,
                  let width = rec.dziWidth, let height = rec.dziHeight,
                  let tileSize = rec.dziTileSize, let overlap = rec.dziOverlap,
                  let format = rec.dziFormat, let maxLevel = rec.dziMaxLevel
            else { return nil }
            return ReadyPackage(
                projectID: projectID, extractedRelDir: extractedRelDir,
                descriptorRelPath: descriptorRelPath, tilesRelDir: tilesRelDir,
                width: width, height: height, tileSize: tileSize, overlap: overlap,
                format: format, maxFolderLevel: maxLevel
            )
        }
    }

    // MARK: - Transitions (each a single write, stamping updated_at)

    func markQueued(projectID: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.queued.rawValue
            rec.downloadProgress = nil
            rec.updatedAt = now
        }
    }

    func beginDownloading(projectID: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.downloading.rawValue
            rec.lastAttemptAt = now
            rec.downloadProgress = 0
            rec.failureReasonRaw = nil
            rec.updatedAt = now
        }
    }

    func setDownloadProgress(projectID: String, _ progress: Double) async throws {
        try await dbWriter.write { db in
            guard var rec = try PackageRecord.fetchOne(db, key: projectID), rec.state == .downloading else { return }
            rec.downloadProgress = min(max(progress, 0), 1)
            rec.updatedAt = clock.now.timeIntervalSince1970
            try rec.update(db)
        }
    }

    func markDownloaded(projectID: String, archiveRelPath: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.downloaded.rawValue
            rec.archiveRelPath = archiveRelPath
            rec.downloadProgress = nil
            rec.failureReasonRaw = nil
            rec.updatedAt = now
        }
    }

    func beginExtracting(projectID: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.extracting.rawValue
            rec.updatedAt = now
        }
    }

    /// Writes the full readiness set atomically; keeps `archive_rel_path` (the offline re-extract
    /// artifact); clears failure/retry/progress and stamps success.
    func markReady(projectID: String, layout: ReadyPackage) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.ready.rawValue
            rec.extractedRelDir = layout.extractedRelDir
            rec.descriptorRelPath = layout.descriptorRelPath
            rec.tilesRelDir = layout.tilesRelDir
            rec.dziWidth = layout.width
            rec.dziHeight = layout.height
            rec.dziTileSize = layout.tileSize
            rec.dziOverlap = layout.overlap
            rec.dziFormat = layout.format
            rec.dziMaxLevel = layout.maxFolderLevel
            rec.downloadProgress = nil
            rec.failureReasonRaw = nil
            rec.retryCount = 0
            rec.nextRetryAt = nil
            rec.lastSuccessAt = now
            rec.updatedAt = now
        }
    }

    func markFailed(
        projectID: String,
        reason: PackageFailureReason,
        retryCount: Int,
        nextRetryAt: Double?,
        clearingArchive: Bool = false
    ) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = PackageState.failed.rawValue
            rec.failureReasonRaw = reason.rawValue
            rec.retryCount = retryCount
            rec.nextRetryAt = nextRetryAt
            rec.downloadProgress = nil
            if clearingArchive {
                rec.archiveRelPath = nil
            }
            rec.updatedAt = now
        }
    }

    /// Makes a failed row immediately due (keeps `retry_count`/backoff history). Used by the
    /// connectivity trigger and launch recovery ("retry on launch").
    func clearNextRetry(projectID: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.nextRetryAt = nil
            rec.updatedAt = now
        }
    }

    /// Recovery helper: move to a safe state, optionally nulling the readiness set and/or archive path.
    func demote(
        projectID: String, to state: PackageState, clearingReadinessSet: Bool, clearingArchive: Bool
    ) async throws {
        try await mutate(projectID) { rec, now in
            rec.stateRaw = state.rawValue
            if clearingReadinessSet {
                rec.extractedRelDir = nil
                rec.descriptorRelPath = nil
                rec.tilesRelDir = nil
                rec.dziWidth = nil
                rec.dziHeight = nil
                rec.dziTileSize = nil
                rec.dziOverlap = nil
                rec.dziFormat = nil
                rec.dziMaxLevel = nil
            }
            if clearingArchive {
                rec.archiveRelPath = nil
            }
            rec.downloadProgress = nil
            rec.updatedAt = now
        }
    }

    func resetRetrySchedule(projectID: String) async throws {
        try await mutate(projectID) { rec, now in
            rec.nextRetryAt = nil
            rec.retryCount = 0
            rec.updatedAt = now
        }
    }

    // MARK: - Helper

    private func mutate(
        _ projectID: String, _ body: @Sendable (inout PackageRecord, _ now: Double) -> Void
    ) async throws {
        let now = clock.now.timeIntervalSince1970
        try await dbWriter.write { db in
            guard var rec = try PackageRecord.fetchOne(db, key: projectID) else { return }
            body(&rec, now)
            try rec.update(db)
        }
    }
}
