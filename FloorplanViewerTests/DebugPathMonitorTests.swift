import Foundation
import Testing
@testable import FloorplanViewer

/// The debug force-offline decorator: it must override reachability, dedup on the **effective**
/// value (so an inner flicker while forced never leaks through), restore the real value when
/// released, and fan every emission out to all registered sinks.
struct DebugPathMonitorTests {
    /// Records the booleans delivered to a sink.
    private final nonisolated class Sink: @unchecked Sendable {
        // @unchecked Sendable: the array is serialized by `lock`.
        private let lock = NSLock()
        private var values: [Bool] = []
        func record(_ value: Bool) {
            lock.withLock { values.append(value) }
        }

        var all: [Bool] {
            lock.withLock { values }
        }
    }

    @Test func forcedOfflineOverridesSatisfiedAndEmitsExactlyOnce() {
        let monitor = DebugPathMonitor(wrapping: StubPathMonitor(satisfied: true))
        let sink = Sink()
        monitor.start { sink.record($0) }

        #expect(monitor.isSatisfied)
        monitor.setForcedOffline(true)
        #expect(!monitor.isSatisfied)
        #expect(monitor.isForcedOffline)
        #expect(sink.all == [false])

        // Forcing offline again is a no-op — the effective value is unchanged.
        monitor.setForcedOffline(true)
        #expect(sink.all == [false])

        // Releasing restores the real inner value and emits once.
        monitor.setForcedOffline(false)
        #expect(monitor.isSatisfied)
        #expect(sink.all == [false, true])
    }

    @Test func innerFlickerWhileForcedNeverLeaksThrough() {
        let inner = StubPathMonitor(satisfied: true)
        let monitor = DebugPathMonitor(wrapping: inner)
        let sink = Sink()
        monitor.start { sink.record($0) }

        monitor.setForcedOffline(true) // effective false → [false]
        inner.set(satisfied: false) // effective still false → no emit
        inner.set(satisfied: true) // effective still false → no emit
        #expect(sink.all == [false])

        monitor.setForcedOffline(false) // effective now tracks inner (true) → emits true
        #expect(sink.all == [false, true])
    }

    @Test func passesThroughInnerUpdatesWhenNotForced() {
        let inner = StubPathMonitor(satisfied: true)
        let monitor = DebugPathMonitor(wrapping: inner)
        let sink = Sink()
        monitor.start { sink.record($0) }

        inner.set(satisfied: false)
        inner.set(satisfied: true)
        #expect(sink.all == [false, true])
        #expect(monitor.isSatisfied)
    }

    @Test func fansOutToEverySink() {
        let monitor = DebugPathMonitor(wrapping: StubPathMonitor(satisfied: true))
        let first = Sink()
        let second = Sink()
        monitor.start { first.record($0) }
        monitor.start { second.record($0) }

        monitor.setForcedOffline(true)
        #expect(first.all == [false])
        #expect(second.all == [false])
    }
}
