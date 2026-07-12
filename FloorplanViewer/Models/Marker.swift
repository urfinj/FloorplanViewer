import Foundation
import GRDB

/// A marker in stable, normalized floorplan coordinates (`0…1`, DB `CHECK`-constrained). Never
/// stored as screen pixels.
nonisolated struct Marker: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var id: String
    var projectID: String
    var normalizedX: Double
    var normalizedY: Double
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case normalizedX = "normalized_x"
        case normalizedY = "normalized_y"
        case createdAt = "created_at"
    }

    static let databaseTableName = "marker"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectID = Column(CodingKeys.projectID)
        static let normalizedX = Column(CodingKeys.normalizedX)
        static let normalizedY = Column(CodingKeys.normalizedY)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}
