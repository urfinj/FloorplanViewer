import Foundation
import GRDB

/// Debug/demo seeding of a deliberately-failing project, kept in the debug folder as an extension so
/// it vanishes with the feature. Uses the repository's own `dbWriter` (same module) — no GRDB leaks
/// into the controller or the view.
extension ProjectRepository {
    /// The demo project's package URL — a 404 today. Upload a valid archive here to make it succeed.
    static let seed404URL = "\(PackageCatalog.baseURL)/samples/sample-4.tar.gz"

    /// Insert one project whose package URL 404s, so a reviewer can watch the failure + backoff UI
    /// without waiting for a real outage (→ `httpStatus` → "Failed — will retry").
    ///
    /// Idempotent: skipped if already present. Sorts after the real projects and is wiped by
    /// "Clear data and reset" (a plain "Reset" keeps it).
    func seed404Project() async throws {
        let spec = PackageCatalog.Spec(
            id: "debug-fail-not-found",
            name: "Demo — not found (404)",
            url: Self.seed404URL
        )
        try await dbWriter.write { db in
            guard try Project.fetchOne(db, key: spec.id) == nil else { return }
            let maxSort = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) FROM project") ?? -1
            try db.execute(
                sql: "INSERT INTO project (id, name, package_url, sort_order) VALUES (?, ?, ?, ?)",
                arguments: [spec.id, spec.name, spec.url, maxSort + 1]
            )
            try db.execute(
                sql: "INSERT INTO package (project_id, state_raw, retry_count, updated_at) VALUES (?, ?, 0, 0)",
                arguments: [spec.id, PackageState.notPrepared.rawValue]
            )
        }
    }
}
