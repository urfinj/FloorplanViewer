import Foundation
import Network
import os

/// Connectivity seam — a protocol so tests emit synthetic path transitions (`StubPathMonitor`)
/// without a real `NWPathMonitor`. The monitor is a scheduling hint, not an oracle: requests can
/// still fail on a "satisfied" path and are classified normally.
nonisolated protocol PathMonitoring: Sendable {
    /// The **current** reachability, not merely the transition.
    var isSatisfied: Bool { get }
    /// Invokes `onUpdate` on every reachability change (both directions — the engine reacts to
    /// restoration, the UI also needs loss).
    func start(onUpdate: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

/// Production adapter over `NWPathMonitor`, delivering updates on a private serial queue.
///
/// **Multi-sink:** each `start(onSatisfied:)` call registers an additional sink (the coordinator
/// and the UI's `ConnectivityState` share one adapter); the underlying monitor starts once.
/// **Single-cycle:** `NWPathMonitor` cannot be restarted once cancelled, so `cancel()` is terminal
/// for this adapter — only tests drive it.
final nonisolated class NWPathMonitorAdapter: PathMonitoring {
    private struct State {
        /// Optimistic until the monitor delivers its first path: the launch drain must not be
        /// gated on a reachability answer that has not arrived yet.
        var satisfied = true
        var sinks: [@Sendable (Bool) -> Void] = []
        var started = false
        var lastDeliveredStatus = true
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.iphoner.floorplanviewer.pathmonitor")
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isSatisfied: Bool {
        state.withLock(\.satisfied)
    }

    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        let shouldStartMonitor = state.withLock { state in
            state.sinks.append(onUpdate)
            if state.started {
                return false
            }
            state.started = true
            return true
        }
        guard shouldStartMonitor else { return }
        monitor.pathUpdateHandler = { [state] path in
            let reachable = path.status == .satisfied
            let sinks = state.withLock { state -> [@Sendable (Bool) -> Void] in
                state.satisfied = reachable
                guard state.lastDeliveredStatus != reachable else { return [] }
                state.lastDeliveredStatus = reachable
                return state.sinks
            }
            for sink in sinks {
                sink(reachable)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
