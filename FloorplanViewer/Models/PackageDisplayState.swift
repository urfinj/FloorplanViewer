import Foundation

/// Presentation state, derived from the durable row + live connectivity — never persisted.
/// The mapping is the plan `00 §7` display table; connectivity is not package truth.
nonisolated enum PackageDisplayState: Equatable, Sendable {
    case preparing(progress: Double?)
    case retrying(attempt: Int, progress: Double?)
    case extracting
    case ready
    case failedWillRetry(reason: PackageFailureReason, nextRetryAt: Double?)
    case unavailableOffline

    static func make(
        state: PackageState,
        reason: PackageFailureReason?,
        retryCount: Int,
        isOffline: Bool,
        progress: Double?,
        nextRetryAt: Double?
    ) -> PackageDisplayState {
        switch state {
        case .ready:
            .ready // ready is ready, offline or not
        case .downloading:
            retryCount > 0
                ? .retrying(attempt: retryCount + 1, progress: progress)
                : .preparing(progress: progress)
        case .extracting, .downloaded:
            retryCount > 0 ? .retrying(attempt: retryCount + 1, progress: nil) : .extracting
        case .notPrepared, .queued:
            isOffline ? .unavailableOffline : .preparing(progress: nil)
        case .failed:
            isOffline
                ? .unavailableOffline
                : .failedWillRetry(reason: reason ?? .unknown, nextRetryAt: nextRetryAt)
        }
    }

    static func make(row: ProjectListRow, isOffline: Bool) -> PackageDisplayState {
        make(
            state: row.state,
            reason: row.failureReason,
            retryCount: row.retryCount,
            isOffline: isOffline,
            progress: row.downloadProgress,
            nextRetryAt: row.nextRetryAt
        )
    }
}
