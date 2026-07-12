import Foundation
import os

/// The single debug knob read from `@concurrent` (background) download code: a per-chunk download
/// delay used by "Slow downloads" so the progress bar is observable. Behind an
/// `OSAllocatedUnfairLock` (the `NWPathMonitorAdapter` posture) for a race-free read off the main
/// actor. Owned by `AppEnvironment`; defaults to 0 (inert), so production behaviour is unchanged
/// until the Debug / Demo sheet flips it.
final nonisolated class DebugControls: Sendable {
    private let chunkDelay = OSAllocatedUnfairLock(initialState: 0)

    /// Per-chunk sleep (milliseconds) the downloader applies. 0 = off (default).
    var chunkDelayMillis: Int {
        chunkDelay.withLock { $0 }
    }

    func setChunkDelayMillis(_ millis: Int) {
        chunkDelay.withLock { $0 = max(0, millis) }
    }
}
