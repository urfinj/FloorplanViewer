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
            return .ready // ready is ready, offline or not
        case .downloading:
            return retryCount > 0
                ? .retrying(attempt: retryCount + 1, progress: meaningfulProgress(progress))
                : .preparing(progress: progress)
        case .extracting, .downloaded:
            return retryCount > 0 ? .retrying(attempt: retryCount + 1, progress: nil) : .extracting
        case .notPrepared, .queued:
            return isOffline ? .unavailableOffline : .preparing(progress: nil)
        case .failed:
            if isOffline {
                return .unavailableOffline
            }
            // While an automatic retry is still scheduled, present the row as *retrying*, not
            // failed. Otherwise the brief in-flight attempt of a fast-failing plan (e.g. a 404)
            // flips the whole row and viewer between a "Retrying" screen and a "Failed" screen on
            // every backoff tick — a jarring blink. Only once auto-retry is exhausted (no
            // `nextRetryAt`) do we surface the distinct failed state with its Retry affordance.
            if nextRetryAt != nil {
                return .retrying(attempt: retryCount + 1, progress: nil)
            }
            return .failedWillRetry(reason: reason ?? .unknown, nextRetryAt: nil)
        }
    }

    /// Treat a 0 (or absent) download fraction as indeterminate. A retry that fails before any
    /// bytes arrive must not flicker the progress indicator between a 0% bar and a spinner.
    private static func meaningfulProgress(_ progress: Double?) -> Double? {
        guard let progress, progress > 0 else { return nil }
        return progress
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
