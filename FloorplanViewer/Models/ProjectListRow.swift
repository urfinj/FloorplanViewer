import Foundation
import GRDB

/// Read model for the project list: a project joined with its package's presentation-relevant
/// fields. Fetched by a single query; the list screen never touches package tables directly.
nonisolated struct ProjectListRow: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var sortOrder: Int
    var stateRaw: String
    var failureReasonRaw: String?
    var downloadProgress: Double?
    var retryCount: Int
    var nextRetryAt: Double?

    var state: PackageState {
        PackageState(rawValue: stateRaw) ?? .notPrepared
    }

    var failureReason: PackageFailureReason? {
        failureReasonRaw.flatMap(PackageFailureReason.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case stateRaw = "state_raw"
        case failureReasonRaw = "failure_reason_raw"
        case downloadProgress = "download_progress"
        case retryCount = "retry_count"
        case nextRetryAt = "next_retry_at"
    }
}
