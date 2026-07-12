import Testing
@testable import FloorplanViewer

/// The locked display table (plan 00 §7) — this is the assignment's offline-availability logic
/// on the UI side.
struct DisplayStateTests {
    @Test func readyIsReadyRegardlessOfConnectivity() {
        for offline in [false, true] {
            let state = PackageDisplayState.make(
                state: .ready, reason: nil, retryCount: 0, isOffline: offline, progress: nil, nextRetryAt: nil
            )
            #expect(state == .ready)
        }
    }

    @Test func firstDownloadShowsPreparingWithProgress() {
        let state = PackageDisplayState.make(
            state: .downloading, reason: nil, retryCount: 0, isOffline: false, progress: 0.4, nextRetryAt: nil
        )
        #expect(state == .preparing(progress: 0.4))
    }

    @Test func inFlightWorkAfterFailuresShowsRetryingWithAttempt() {
        let downloading = PackageDisplayState.make(
            state: .downloading, reason: nil, retryCount: 2, isOffline: false, progress: 0.1, nextRetryAt: nil
        )
        #expect(downloading == .retrying(attempt: 3, progress: 0.1))
        let extracting = PackageDisplayState.make(
            state: .extracting, reason: nil, retryCount: 1, isOffline: false, progress: nil, nextRetryAt: nil
        )
        #expect(extracting == .retrying(attempt: 2, progress: nil))
    }

    @Test func extractingAndDownloadedShowExtracting() {
        for state in [PackageState.extracting, .downloaded] {
            let display = PackageDisplayState.make(
                state: state, reason: nil, retryCount: 0, isOffline: false, progress: nil, nextRetryAt: nil
            )
            #expect(display == .extracting)
        }
    }

    @Test func unpreparedShowsPreparingOnlineAndUnavailableOffline() {
        for state in [PackageState.notPrepared, .queued] {
            #expect(PackageDisplayState.make(
                state: state, reason: nil, retryCount: 0, isOffline: false, progress: nil, nextRetryAt: nil
            ) == .preparing(progress: nil))
            #expect(PackageDisplayState.make(
                state: state, reason: nil, retryCount: 0, isOffline: true, progress: nil, nextRetryAt: nil
            ) == .unavailableOffline)
        }
    }

    @Test func failedShowsRetryInfoOnlineAndUnavailableOffline() {
        // Auto-retry still scheduled → present as retrying (stable) so the cell/viewer don't blink
        // between a "Retrying" and a "Failed" screen on every backoff tick.
        #expect(PackageDisplayState.make(
            state: .failed, reason: .httpStatus, retryCount: 3, isOffline: false, progress: nil, nextRetryAt: 123
        ) == .retrying(attempt: 4, progress: nil))
        // Auto-retry exhausted (no schedule) → the distinct failed state with a Retry affordance.
        #expect(PackageDisplayState.make(
            state: .failed, reason: .httpStatus, retryCount: 6, isOffline: false, progress: nil, nextRetryAt: nil
        ) == .failedWillRetry(reason: .httpStatus, nextRetryAt: nil))
        // Offline is never a failure.
        #expect(PackageDisplayState.make(
            state: .failed, reason: .network, retryCount: 3, isOffline: true, progress: nil, nextRetryAt: 123
        ) == .unavailableOffline)
    }
}
