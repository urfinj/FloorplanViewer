import Foundation
import GRDB

/// Typed open/migrate failure surfaced to the recovery UI — never `fatalError`.
nonisolated enum AppDatabaseError: Error, Sendable {
    case couldNotOpen(any Error)
    case migrationFailed(any Error)
}

/// The persistence core: a WAL `DatabasePool`, forward-only migrations, seed in `v1`.
final nonisolated class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens the pool at `path` and migrates.
    init(path: String) throws {
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: Self.makeConfiguration())
        } catch {
            Log.data.error("Database open failed: \(String(describing: error), privacy: .public)")
            throw AppDatabaseError.couldNotOpen(error)
        }
        writer = pool
        try Self.migrate(pool)
    }

    /// In-memory store for tests (a `DatabaseQueue`; WAL does not apply to `:memory:`).
    private init(inMemoryWriter: any DatabaseWriter) throws {
        writer = inMemoryWriter
        try Self.migrate(inMemoryWriter)
    }

    /// Opens the shared on-disk store (creates its directory).
    static func makeShared() throws -> AppDatabase {
        let url = try AppContainer.databaseURL()
        return try AppDatabase(path: url.path)
    }

    /// In-memory database for tests.
    static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: makeConfiguration())
        return try AppDatabase(inMemoryWriter: queue)
    }

    /// Closes the pool — checkpoints the WAL and releases the underlying file handles — so the
    /// store files can be removed without racing an open connection. Best-effort: used by the debug
    /// "Clear data and reset" just before the process terminates.
    func close() {
        do {
            try writer.close()
        } catch {
            Log.data.error("Database close failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5.0)
        return config
    }

    // MARK: - Migrations (forward-only; never mutate a shipped migration)

    private static func migrate(_ writer: any DatabaseWriter) throws {
        do {
            try makeMigrator(eraseDatabaseOnSchemaChange: isDebugBuild).migrate(writer)
        } catch {
            Log.data.error("Database migration failed: \(String(describing: error), privacy: .public)")
            throw AppDatabaseError.migrationFailed(error)
        }
    }

    #if DEBUG
        static let isDebugBuild = true
    #else
        static let isDebugBuild = false
    #endif

    static func makeMigrator(eraseDatabaseOnSchemaChange: Bool) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = eraseDatabaseOnSchemaChange

        migrator.registerMigration("v1_schema") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("package_url", .text).notNull()
                t.column("sort_order", .integer).notNull().unique()
            }

            try db.create(table: "package") { t in
                t.primaryKey("project_id", .text)
                    .references("project", onDelete: .cascade)
                t.column("state_raw", .text).notNull().defaults(to: PackageState.notPrepared.rawValue)
                t.column("archive_rel_path", .text)
                t.column("extracted_rel_dir", .text)
                t.column("descriptor_rel_path", .text)
                t.column("tiles_rel_dir", .text)
                t.column("dzi_width", .integer)
                t.column("dzi_height", .integer)
                t.column("dzi_tile_size", .integer)
                t.column("dzi_overlap", .integer)
                t.column("dzi_format", .text)
                t.column("dzi_max_level", .integer)
                // NULL passes the CHECK (SQLite treats NULL as satisfied); only out-of-range fails.
                t.column("download_progress", .double).check { $0 >= 0 && $0 <= 1 }
                t.column("failure_reason_raw", .text)
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("next_retry_at", .double)
                t.column("last_attempt_at", .double)
                t.column("last_success_at", .double)
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "marker") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().indexed()
                    .references("project", onDelete: .cascade)
                t.column("normalized_x", .double).notNull().check { $0 >= 0 && $0 <= 1 }
                t.column("normalized_y", .double).notNull().check { $0 >= 0 && $0 <= 1 }
                t.column("created_at", .double).notNull()
            }

            try db.create(table: "appState") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("last_selected_project_id", .text)
                    .references("project", onDelete: .setNull)
                t.column("updated_at", .double).notNull()
            }

            // Seed (runs once with the migration; timestamps are 0 sentinels until first transition).
            for (index, spec) in PackageCatalog.seed.enumerated() {
                try db.execute(
                    sql: "INSERT INTO project (id, name, package_url, sort_order) VALUES (?, ?, ?, ?)",
                    arguments: [spec.id, spec.name, spec.url, index]
                )
                try db.execute(
                    sql: "INSERT INTO package (project_id, state_raw, retry_count, updated_at) VALUES (?, ?, 0, 0)",
                    arguments: [spec.id, PackageState.notPrepared.rawValue]
                )
            }
            try db.execute(sql: "INSERT INTO appState (id, last_selected_project_id, updated_at) VALUES (1, NULL, 0)")
        }

        return migrator
    }
}
