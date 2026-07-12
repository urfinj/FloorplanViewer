import Foundation

/// Typed launch failure surfaced to the recovery UI — a recoverable condition is never a
/// `fatalError`. The underlying detail is kept for logs; `userMessage` is the safe on-screen text.
nonisolated enum AppLaunchError: Error, Sendable, Equatable {
    case databaseOpenFailed(underlying: String)
    case recoveryFailed(underlying: String)

    /// Safe, user-facing message (no raw system detail, no paths).
    var userMessage: String {
        switch self {
        case .databaseOpenFailed:
            "The local data store could not be opened."
        case .recoveryFailed:
            "The app could not recover its saved state."
        }
    }
}
