import Foundation

/// Injectable wall-clock. Production uses `SystemClock`; tests inject a controllable clock so
/// retry timing and timestamps are deterministic.
nonisolated protocol AppClock: Sendable {
    var now: Date { get }
}

/// Production clock.
nonisolated struct SystemClock: AppClock {
    var now: Date {
        Date()
    }
}
