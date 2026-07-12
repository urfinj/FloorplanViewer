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

    /// Short, safe on-screen phrasing — shared by the row caption and the viewer's failed pane.
    var userDescription: String {
        switch self {
        case .network: "Network problem"
        case .httpStatus: "Server error"
        case .corruptArchive: "Damaged download"
        case .extractionFailed: "Couldn’t unpack"
        case .descriptorNotFound, .descriptorInvalid, .tilesMissing: "Package content invalid"
        case .diskFull: "Not enough storage"
        case .unknown: "Something went wrong"
        }
    }
}
