import Foundation
import GRDB

/// Marker persistence. Coordinates are clamped to `0…1` before the DB `CHECK` ever sees them.
nonisolated struct MarkerRepository: Sendable {
    let dbWriter: any DatabaseWriter
    let clock: any AppClock

    @discardableResult
    func insert(projectID: String, normalizedX: Double, normalizedY: Double) async throws -> Marker {
        let marker = Marker(
            id: UUID().uuidString,
            projectID: projectID,
            normalizedX: min(max(normalizedX, 0), 1),
            normalizedY: min(max(normalizedY, 0), 1),
            createdAt: clock.now.timeIntervalSince1970
        )
        try await dbWriter.write { db in try marker.insert(db) }
        return marker
    }

    func delete(id: String) async throws {
        try await dbWriter.write { db in _ = try Marker.deleteOne(db, key: id) }
    }

    func fetchAll(projectID: String) async throws -> [Marker] {
        try await dbWriter.read { db in
            try Marker
                .filter(Marker.Columns.projectID == projectID)
                .order(Marker.Columns.createdAt)
                .fetchAll(db)
        }
    }

    func observeMarkers(projectID: String) -> AsyncValueObservation<[Marker]> {
        ValueObservation
            .tracking { db in
                try Marker
                    .filter(Marker.Columns.projectID == projectID)
                    .order(Marker.Columns.createdAt)
                    .fetchAll(db)
            }
            .values(in: dbWriter)
    }
}
