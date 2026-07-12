import Foundation

/// Extraction seam. Unpacks the `.tar.gz` at `archiveURL` into `directory` (created if needed).
/// Implementations guard against hostile entries and throw `PreparationError` (`.corruptArchive`
/// for undecodable input) — cancellation rethrows untouched.
nonisolated protocol ArchiveExtracting: Sendable {
    func extract(archiveURL: URL, into directory: URL) async throws
}
