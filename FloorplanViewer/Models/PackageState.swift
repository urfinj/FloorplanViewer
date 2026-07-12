import Foundation

/// The durable package preparation state (persisted as `state_raw`). Presentation state is
/// derived from this plus connectivity/retry timing — never persisted (see `PackageDisplayState`).
nonisolated enum PackageState: String, Sendable, CaseIterable, Equatable {
    case notPrepared
    case queued
    case downloading
    case downloaded
    case extracting
    case ready
    case failed
}
