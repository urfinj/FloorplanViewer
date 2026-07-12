import Foundation
@testable import FloorplanViewer

/// Scriptable connectivity: tests flip `satisfied` and fire the sinks synthetically.
final class StubPathMonitor: PathMonitoring, @unchecked Sendable {
    // @unchecked Sendable: all mutable state is serialized by `lock`.
    private let lock = NSLock()
    private var satisfied: Bool
    private var sinks: [@Sendable () -> Void] = []

    init(satisfied: Bool = true) {
        self.satisfied = satisfied
    }

    var isSatisfied: Bool {
        lock.withLock { satisfied }
    }

    /// Multi-sink like the production adapter: every registered sink fires on satisfaction.
    func start(onSatisfied: @escaping @Sendable () -> Void) {
        lock.withLock { sinks.append(onSatisfied) }
    }

    func cancel() {
        lock.withLock { sinks.removeAll() }
    }

    /// Set reachability; when it becomes satisfied, fire the captured sinks (like NWPathMonitor).
    func set(satisfied newValue: Bool) {
        let callbacks = lock.withLock {
            satisfied = newValue
            return newValue ? sinks : []
        }
        for callback in callbacks {
            callback()
        }
    }
}
