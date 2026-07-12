import GRDB
import Testing
@testable import FloorplanViewer

struct AppDatabaseTests {
    @Test func migrationSeedsThreeProjectsAndPackages() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.read { db in
            #expect(try Project.fetchCount(db) == 3)
            #expect(try PackageRecord.fetchCount(db) == 3)
            #expect(try AppStateRecord.fetchCount(db) == 1)
            let projects = try Project.order(Project.Columns.sortOrder).fetchAll(db)
            #expect(projects.map(\.id) == ["project-1", "project-2", "project-3"])
            #expect(projects.map(\.name) == ["Project 1", "Project 2", "Project 3"])
            let packages = try PackageRecord.fetchAll(db)
            #expect(packages.allSatisfy { $0.state == .notPrepared })
            #expect(try Project.fetchOne(db, key: "project-1")?.packageURL.hasSuffix("sample-1.tar.gz") == true)
        }
    }

    @Test func foreignKeysAreEnforced() async throws {
        let db = try AppDatabase.inMemory()
        let threw = await didThrow {
            try await db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO marker (id, project_id, normalized_x, normalized_y, created_at)
                VALUES ('m1', 'nonexistent', 0.5, 0.5, 0)
                """)
            }
        }
        #expect(threw)
    }

    @Test(arguments: [
        "INSERT INTO marker (id, project_id, normalized_x, normalized_y, created_at) VALUES ('m','project-1',2.0,0.5,0)",
        "INSERT INTO marker (id, project_id, normalized_x, normalized_y, created_at) VALUES ('m','project-1',0.5,-0.1,0)",
        "UPDATE package SET download_progress = 1.5 WHERE project_id = 'project-1'"
    ])
    func checkConstraintsRejectOutOfRange(sql: String) async throws {
        let db = try AppDatabase.inMemory()
        let threw = await didThrow {
            try await db.writer.write { db in try db.execute(sql: sql) }
        }
        #expect(threw)
    }

    @Test func nullDownloadProgressIsAllowed() async throws {
        let db = try AppDatabase.inMemory()
        // Seed rows have NULL download_progress; a write leaving it NULL must succeed.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE package SET state_raw = 'queued' WHERE project_id = 'project-1'")
        }
        let state = try await db.writer.read { db in
            try PackageRecord.fetchOne(db, key: "project-1")?.state
        }
        #expect(state == .queued)
    }

    @Test func unknownRawEnumsDecodeToFallback() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try db
                .execute(
                    sql: "UPDATE package SET state_raw = 'garbage', failure_reason_raw = 'bogus' WHERE project_id = 'project-1'"
                )
        }
        let rec = try await db.writer.read { db in try PackageRecord.fetchOne(db, key: "project-1") }
        #expect(rec?.state == .notPrepared) // safe fallback
        #expect(rec?.failureReason == nil)
    }
}

/// Returns whether the async operation threw, without failing the test on either outcome.
func didThrow(_ operation: () async throws -> Void) async -> Bool {
    do {
        try await operation()
        return false
    } catch {
        return true
    }
}
