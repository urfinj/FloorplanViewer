import Foundation

/// Live reachability for display mapping — a second sink on the app's one shared path monitor
/// (the coordinator is the other). A hint for labels only; package truth stays in the DB.
@MainActor
@Observable
final class ConnectivityState {
    private(set) var isOffline: Bool

    init(monitor: any PathMonitoring) {
        isOffline = !monitor.isSatisfied
        monitor.start { [weak self] isSatisfied in
            Task { @MainActor [weak self] in
                self?.isOffline = !isSatisfied
            }
        }
    }
}
