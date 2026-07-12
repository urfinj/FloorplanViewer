import Foundation
import os

/// A `PathMonitoring` decorator adding a debug **force-offline** override over any inner monitor
/// (production: `NWPathMonitorAdapter`). Effective reachability is `forcedOffline ? false :
/// innerSatisfied`; inner updates and force-flag flips both fan out to the registered sinks, deduped
/// on the **effective** value. `DebugSupport` wraps the monitor once, so the override reaches both
/// sinks — the engine's connectivity trigger and the UI's `ConnectivityState`.
///
/// Sendable via `OSAllocatedUnfairLock` (same posture as `NWPathMonitorAdapter`): the debug setter
/// runs on the main actor while sinks fire from the inner monitor's queue.
final nonisolated class DebugPathMonitor: PathMonitoring {
    private let inner: any PathMonitoring

    private struct State {
        var forcedOffline = false
        var innerSatisfied: Bool
        var sinks: [@Sendable (Bool) -> Void] = []
        var started = false
        var lastDelivered: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    init(wrapping inner: any PathMonitoring) {
        self.inner = inner
        let seed = inner.isSatisfied // NWPathMonitorAdapter seeds optimistic `true`
        state = OSAllocatedUnfairLock(initialState: State(innerSatisfied: seed, lastDelivered: seed))
    }

    var isSatisfied: Bool {
        state.withLock { $0.forcedOffline ? false : $0.innerSatisfied }
    }

    var isForcedOffline: Bool {
        state.withLock(\.forcedOffline)
    }

    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        let startInner = state.withLock { state -> Bool in
            state.sinks.append(onUpdate)
            defer { state.started = true }
            return !state.started // start the inner monitor exactly once across multiple sinks
        }
        guard startInner else { return }
        inner.start { [state] innerSatisfied in
            let delivery = state.withLock { state -> (Bool, [@Sendable (Bool) -> Void])? in
                state.innerSatisfied = innerSatisfied
                let effective = state.forcedOffline ? false : innerSatisfied
                guard state.lastDelivered != effective else { return nil }
                state.lastDelivered = effective
                return (effective, state.sinks)
            }
            guard let (value, sinks) = delivery else { return }
            for sink in sinks {
                sink(value)
            }
        }
    }

    func cancel() {
        inner.cancel()
    }

    /// Debug knob — flips the force-offline override and synthesises an effective-value update so
    /// every sink (labels included) reacts live. Callable from `DebugController` on the main actor.
    func setForcedOffline(_ forced: Bool) {
        let delivery = state.withLock { state -> (Bool, [@Sendable (Bool) -> Void])? in
            state.forcedOffline = forced
            let effective = forced ? false : state.innerSatisfied
            guard state.lastDelivered != effective else { return nil }
            state.lastDelivered = effective
            return (effective, state.sinks)
        }
        guard let (value, sinks) = delivery else { return }
        for sink in sinks {
            sink(value)
        }
    }
}
