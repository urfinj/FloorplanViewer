import Foundation
import GRDB

/// The package state-machine row (one per project, PK = `project_id`). The six `dzi*` fields plus
/// the two path fields form the **readiness set**: written together in `markReady`, cleared
/// together on demotion, and only read through `ReadyPackage` (complete-or-absent).
nonisolated struct PackageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var projectID: String
    var stateRaw: String
    var archiveRelPath: String?
    var extractedRelDir: String?
    var descriptorRelPath: String?
    var tilesRelDir: String?
    var dziWidth: Int?
    var dziHeight: Int?
    var dziTileSize: Int?
    var dziOverlap: Int?
    var dziFormat: String?
    var dziMaxLevel: Int?
    var downloadProgress: Double?
    var failureReasonRaw: String?
    var retryCount: Int
    var nextRetryAt: Double?
    var lastAttemptAt: Double?
    var lastSuccessAt: Double?
    var updatedAt: Double

    /// Typed state; an unrecognized raw value decodes to a safe fallback rather than crashing.
    var state: PackageState {
        PackageState(rawValue: stateRaw) ?? .notPrepared
    }

    var failureReason: PackageFailureReason? {
        failureReasonRaw.flatMap(PackageFailureReason.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case stateRaw = "state_raw"
        case archiveRelPath = "archive_rel_path"
        case extractedRelDir = "extracted_rel_dir"
        case descriptorRelPath = "descriptor_rel_path"
        case tilesRelDir = "tiles_rel_dir"
        case dziWidth = "dzi_width"
        case dziHeight = "dzi_height"
        case dziTileSize = "dzi_tile_size"
        case dziOverlap = "dzi_overlap"
        case dziFormat = "dzi_format"
        case dziMaxLevel = "dzi_max_level"
        case downloadProgress = "download_progress"
        case failureReasonRaw = "failure_reason_raw"
        case retryCount = "retry_count"
        case nextRetryAt = "next_retry_at"
        case lastAttemptAt = "last_attempt_at"
        case lastSuccessAt = "last_success_at"
        case updatedAt = "updated_at"
    }

    static let databaseTableName = "package"

    enum Columns {
        static let projectID = Column(CodingKeys.projectID)
        static let stateRaw = Column(CodingKeys.stateRaw)
        static let downloadProgress = Column(CodingKeys.downloadProgress)
        static let nextRetryAt = Column(CodingKeys.nextRetryAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
