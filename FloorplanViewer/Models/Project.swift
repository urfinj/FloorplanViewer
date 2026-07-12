import Foundation
import GRDB

/// A construction project. Seeded once; immutable at runtime.
nonisolated struct Project: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var id: String
    var name: String
    var packageURL: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case packageURL = "package_url"
        case sortOrder = "sort_order"
    }

    static let databaseTableName = "project"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let packageURL = Column(CodingKeys.packageURL)
        static let sortOrder = Column(CodingKeys.sortOrder)
    }
}
