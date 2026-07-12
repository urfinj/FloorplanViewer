import Foundation

/// A preparation step failure carrying the persisted `PackageFailureReason` and whether the step
/// merely observed the network go away. `wentOffline` parks work in `queued` without charging an
/// attempt or recording a failure — being offline is a condition, not an error.
nonisolated struct PreparationError: Error, Sendable, Equatable {
    let reason: PackageFailureReason
    var wentOffline = false

    /// Maps any step error onto a `PreparationError`. Callers must classify cancellation FIRST
    /// (`error is CancellationError` / `Task.isCancelled`) — this function never sees it.
    static func classify(_ error: any Error) -> PreparationError {
        if let prepared = error as? PreparationError {
            return prepared
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return PreparationError(reason: .network, wentOffline: true)
            default:
                return PreparationError(reason: .network)
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return PreparationError(reason: .diskFull)
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return PreparationError(reason: .diskFull)
        }
        return PreparationError(reason: .unknown)
    }
}
