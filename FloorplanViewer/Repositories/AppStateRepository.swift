import Foundation
import GRDB

/// Last-selected-project persistence (singleton `appState` row).
nonisolated struct AppStateRepository: Sendable {
    let dbWriter: any DatabaseWriter
    let clock: any AppClock

    func lastSelectedProjectID() async throws -> String? {
        try await dbWriter.read { db in
            try AppStateRecord.fetchOne(db, key: 1)?.lastSelectedProjectID
        }
    }

    func setLastSelectedProjectID(_ id: String?) async throws {
        let now = clock.now.timeIntervalSince1970
        try await dbWriter.write { db in
            guard var rec = try AppStateRecord.fetchOne(db, key: 1) else { return }
            rec.lastSelectedProjectID = id
            rec.updatedAt = now
            try rec.update(db)
        }
    }
}
