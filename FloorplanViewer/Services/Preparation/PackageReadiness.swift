import Foundation

/// The "never blindly trust the database" check, shared by the coordinator, launch recovery, and
/// the viewer's open path: a `ready` row counts only when its **entire readiness set** is present
/// AND the files are actually on disk. Requiring every metadata column here keeps this check in
/// lockstep with `readyPackage(projectID:)` — a partially populated row can neither render nor
/// linger as "ready": it demotes and re-prepares.
nonisolated enum PackageReadiness {
    /// Verifies the full readiness column set plus descriptor, tile dir, and **both** corner
    /// probe tiles of the full-resolution level. Any gap → not ready (caller demotes).
    static func filesPresent(for record: PackageRecord, storage: PackageStorage) -> Bool {
        guard record.state == .ready,
              record.extractedRelDir != nil,
              let descriptorRelPath = record.descriptorRelPath,
              let tilesRelDir = record.tilesRelDir,
              let width = record.dziWidth,
              let height = record.dziHeight,
              let tileSize = record.dziTileSize, tileSize > 0,
              record.dziOverlap != nil,
              let format = record.dziFormat,
              let maxLevel = record.dziMaxLevel
        else { return false }
        guard storage.fileExists(atRelative: descriptorRelPath),
              storage.directoryExists(atRelative: tilesRelDir)
        else { return false }
        let cols = (width + tileSize - 1) / tileSize
        let rows = (height + tileSize - 1) / tileSize
        let probes = [
            "\(tilesRelDir)/\(maxLevel)/0_0.\(format)",
            "\(tilesRelDir)/\(maxLevel)/\(cols - 1)_\(rows - 1).\(format)"
        ]
        return probes.allSatisfy { storage.fileExists(atRelative: $0) }
    }
}
