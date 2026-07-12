import Foundation

/// Polls `condition` until it holds or `deadline` seconds elapse. For asserting on work driven by
/// real-time timers/callbacks without fragile fixed sleeps (the suite runs parallelized — fixed
/// sleeps stretch under load).
func eventually(
    deadline: TimeInterval = 3,
    interval: Duration = .milliseconds(20),
    _ condition: () async -> Bool
) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval) // polling cadence, not control flow — cancellation irrelevant here
    }
    return await condition()
}
