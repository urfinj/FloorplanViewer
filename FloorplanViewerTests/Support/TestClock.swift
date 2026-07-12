import Foundation
@testable import FloorplanViewer

/// A controllable clock for deterministic timestamp/retry tests.
final class TestClock: AppClock, @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`_now`) is serialized by `lock`.
    private let lock = NSLock()
    private var _now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        _now = now
    }

    var now: Date {
        lock.withLock { _now }
    }

    func set(_ date: Date) {
        lock.withLock { _now = date }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }
}
