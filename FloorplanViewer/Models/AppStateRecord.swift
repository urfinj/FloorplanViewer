import Foundation
import GRDB

/// Singleton app-state row (`id = 1`). Holds the last selected project so the split view restores
/// it on relaunch. Selection lives in GRDB (the assignment requires persisting it), not `@AppStorage`.
nonisolated struct AppStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var id: Int
    var lastSelectedProjectID: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case lastSelectedProjectID = "last_selected_project_id"
        case updatedAt = "updated_at"
    }

    static let databaseTableName = "appState"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let lastSelectedProjectID = Column(CodingKeys.lastSelectedProjectID)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
