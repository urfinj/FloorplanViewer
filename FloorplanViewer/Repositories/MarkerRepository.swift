import Foundation
import GRDB

/// Marker persistence. Coordinates are clamped to `0…1` before the DB `CHECK` ever sees them.
nonisolated struct MarkerRepository: Sendable {
    let dbWriter: any DatabaseWriter
    let clock: any AppClock

    /// Builds a marker with a fresh id + timestamp, coordinates clamped to the DB's `0…1` CHECK.
    /// Split out from `insert` so the UI can render a pin optimistically and then persist the very
    /// same value (same id/coords/timestamp) without a placement round-trip.
    func makeMarker(projectID: String, normalizedX: Double, normalizedY: Double) -> Marker {
        Marker(
            id: UUID().uuidString,
            projectID: projectID,
            normalizedX: min(max(normalizedX, 0), 1),
            normalizedY: min(max(normalizedY, 0), 1),
            createdAt: clock.now.timeIntervalSince1970
        )
    }

    func insert(_ marker: Marker) async throws {
        try await dbWriter.write { db in try marker.insert(db) }
    }

    @discardableResult
    func insert(projectID: String, normalizedX: Double, normalizedY: Double) async throws -> Marker {
        let marker = makeMarker(projectID: projectID, normalizedX: normalizedX, normalizedY: normalizedY)
        try await insert(marker)
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
