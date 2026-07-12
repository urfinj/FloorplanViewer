import Foundation

/// Why the last *real* preparation attempt failed (persisted as `failure_reason_raw`). Being
/// offline is never a failure — it parks work in `queued` without recording a reason.
nonisolated enum PackageFailureReason: String, Sendable, CaseIterable, Equatable {
    case network
    case httpStatus
    case corruptArchive
    case extractionFailed
    case descriptorNotFound
    case descriptorInvalid
    case tilesMissing
    case diskFull
    case unknown
}
