import Foundation
@testable import FloorplanViewer

/// Scriptable connectivity: tests flip `satisfied` and fire the sinks synthetically.
final class StubPathMonitor: PathMonitoring, @unchecked Sendable {
    // @unchecked Sendable: all mutable state is serialized by `lock`.
    private let lock = NSLock()
    private var satisfied: Bool
    private var sinks: [@Sendable (Bool) -> Void] = []

    init(satisfied: Bool = true) {
        self.satisfied = satisfied
    }

    var isSatisfied: Bool {
        lock.withLock { satisfied }
    }

    /// Multi-sink like the production adapter: registered sinks fire on actual status changes.
    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { sinks.append(onUpdate) }
    }

    func cancel() {
        lock.withLock { sinks.removeAll() }
    }

    /// Set reachability and fire the captured sinks (like NWPathMonitor's update handler).
    func set(satisfied newValue: Bool) {
        let callbacks = lock.withLock {
            guard satisfied != newValue else { return [@Sendable (Bool) -> Void]() }
            satisfied = newValue
            return sinks
        }
        for callback in callbacks {
            callback(newValue)
        }
    }
}
