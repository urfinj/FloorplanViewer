import Foundation
import os

/// What recovery did at launch — logged for the console story and asserted in tests.
nonisolated struct RecoveryReport: Sendable, Equatable {
    var normalizedProjects: [String] = []
    var clearedRetrySchedules: [String] = []
    var orphansRemoved: [String] = []
}

/// Reconciles database state with disk **before** any UI or preparation runs, so nothing ever
/// observes (or resumes from) an inconsistent store. Runs the plan's recovery matrix:
/// in-flight states demote to the nearest safe checkpoint by surviving artifacts; `ready` rows
/// are re-verified; `failed` rows become due (retry-on-launch); staging is wiped; orphan files
/// no row references are swept. Markers are never touched.
nonisolated struct LaunchRecovery: Sendable {
    let packages: PackageRepository
    let storage: PackageStorage
    var logger: Logger = Log.app

    @concurrent
    @discardableResult
    func recover() async throws -> RecoveryReport {
        var report = RecoveryReport()
        try storage.wipeStaging()

        let records = try await packages.fetchAll()
        for record in records {
            let projectID = record.projectID
            let archivePresent = record.archiveRelPath.map { storage.fileExists(atRelative: $0) } ?? false
            switch record.state {
            case .downloading, .extracting:
                // The process died mid-flight; demote by surviving artifacts.
                try await packages.demote(
                    projectID: projectID,
                    to: archivePresent ? .downloaded : .queued,
                    clearingReadinessSet: true,
                    clearingArchive: !archivePresent
                )
                report.normalizedProjects.append(projectID)
            case .downloaded:
                if !archivePresent {
                    try await packages.demote(
                        projectID: projectID,
                        to: .queued,
                        clearingReadinessSet: true,
                        clearingArchive: true
                    )
                    report.normalizedProjects.append(projectID)
                }
            case .ready:
                if !PackageReadiness.filesPresent(for: record, storage: storage) {
                    try await packages.demote(
                        projectID: projectID,
                        to: archivePresent ? .downloaded : .queued,
                        clearingReadinessSet: true,
                        clearingArchive: !archivePresent
                    )
                    report.normalizedProjects.append(projectID)
                }
            case .failed:
                if record.nextRetryAt != nil {
                    try await packages.clearNextRetry(projectID: projectID)
                    report.clearedRetrySchedules.append(projectID)
                }
            case .notPrepared, .queued:
                break
            }
        }

        // Sweep against the *post-normalization* rows, so paths cleared by a demotion above are
        // treated as unreferenced and their leftover files are removed.
        let normalized = try await packages.fetchAll()
        report.orphansRemoved = try sweepOrphans(records: normalized)
        logger.notice("Launch recovery: \(String(describing: report), privacy: .public)")
        return report
    }

    /// Deletes archives and extracted trees that no package row references. Referenced paths are
    /// re-read from the *post-normalization* rows so nothing just demoted loses its archive.
    private func sweepOrphans(records: [PackageRecord]) throws -> [String] {
        var removed: [String] = []
        let referencedArchives = Set(records.compactMap(\.archiveRelPath))
        let referencedExtracted = Set(records.compactMap(\.extractedRelDir))

        removed += try sweep(directory: "archives", referenced: referencedArchives)
        removed += try sweep(directory: "extracted", referenced: referencedExtracted)
        return removed
    }

    private func sweep(directory: String, referenced: Set<String>) throws -> [String] {
        guard let dirURL = storage.absoluteURL(for: directory),
              FileManager.default.fileExists(atPath: dirURL.path)
        else { return [] }
        var removed: [String] = []
        let children = try FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        for child in children {
            let relPath = "\(directory)/\(child.lastPathComponent)"
            if !referenced.contains(relPath) {
                try FileManager.default.removeItem(at: child)
                removed.append(relPath)
            }
        }
        return removed
    }
}
