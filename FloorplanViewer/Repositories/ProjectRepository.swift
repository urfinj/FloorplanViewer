import Foundation
import GRDB

/// Reads projects and the joined list rows. `nonisolated`, `Sendable`; SwiftUI never sees GRDB.
nonisolated struct ProjectRepository: Sendable {
    let dbWriter: any DatabaseWriter

    private static let listSQL = """
    SELECT p.id AS id, p.name AS name, p.sort_order AS sort_order,
           k.state_raw AS state_raw, k.failure_reason_raw AS failure_reason_raw,
           k.download_progress AS download_progress, k.retry_count AS retry_count,
           k.next_retry_at AS next_retry_at
    FROM project p
    JOIN package k ON k.project_id = p.id
    ORDER BY p.sort_order ASC
    """

    func fetchAll() async throws -> [Project] {
        try await dbWriter.read { db in
            try Project.order(Project.Columns.sortOrder).fetchAll(db)
        }
    }

    func fetch(id: String) async throws -> Project? {
        try await dbWriter.read { db in try Project.fetchOne(db, key: id) }
    }

    func fetchProjectList() async throws -> [ProjectListRow] {
        try await dbWriter.read { db in
            try ProjectListRow.fetchAll(db, sql: Self.listSQL)
        }
    }

    /// Reactive list, emitting a fresh snapshot on any project/package change.
    func observeProjectList() -> AsyncValueObservation<[ProjectListRow]> {
        ValueObservation
            .tracking { db in try ProjectListRow.fetchAll(db, sql: Self.listSQL) }
            .values(in: dbWriter)
    }
}
