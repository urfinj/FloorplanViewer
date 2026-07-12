import Foundation

/// The non-standard `dzi.json` sidecar emitted alongside vips tile exports.
///
/// **Cross-check only.** Runtime correctness never depends on this file (plan 00 §4): the `.dzi`
/// descriptor and the on-disk pyramid are authoritative. Its absence is not an error; when it is
/// present, the validator decodes it and logs any ``discrepancies(against:maxFolderLevel:)`` as a
/// warning — it is never trusted to override the descriptor.
nonisolated struct DZIJSONSidecar: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let tileSize: Int
    let tileOverlap: Int
    let tileFormat: String
    let maxLevel: Int

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case tileSize = "tile_size"
        case tileOverlap = "tile_overlap"
        case tileFormat = "tile_format"
        case maxLevel = "max_level"
    }

    /// Pure comparison against the authoritative descriptor and disk-discovered max folder level.
    /// Returns a human-readable line per mismatch; an empty result means the sidecar is consistent.
    /// `tileFormat` is compared case-insensitively against the (already lowercased) descriptor.
    func discrepancies(against descriptor: DZIDescriptor, maxFolderLevel: Int) -> [String] {
        var mismatches: [String] = []
        if width != descriptor.width {
            mismatches.append("width: sidecar \(width) vs descriptor \(descriptor.width)")
        }
        if height != descriptor.height {
            mismatches.append("height: sidecar \(height) vs descriptor \(descriptor.height)")
        }
        if tileSize != descriptor.tileSize {
            mismatches.append("tileSize: sidecar \(tileSize) vs descriptor \(descriptor.tileSize)")
        }
        if tileOverlap != descriptor.overlap {
            mismatches.append("overlap: sidecar \(tileOverlap) vs descriptor \(descriptor.overlap)")
        }
        if tileFormat.lowercased() != descriptor.format {
            mismatches.append("format: sidecar \(tileFormat) vs descriptor \(descriptor.format)")
        }
        if maxLevel != maxFolderLevel {
            mismatches.append("maxLevel: sidecar \(maxLevel) vs disk \(maxFolderLevel)")
        }
        return mismatches
    }

    /// Best-effort cross-check of a `dzi.json` next to the descriptor: absent or undecodable is
    /// fine; mismatches are logged as warnings and never affect the outcome.
    static func crossCheck(descriptor: DZIDescriptor, maxFolderLevel: Int, near descriptorURL: URL) {
        let sidecarURL = descriptorURL.deletingLastPathComponent().appending(path: "dzi.json")
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(DZIJSONSidecar.self, from: data)
        else { return }
        for line in sidecar.discrepancies(against: descriptor, maxFolderLevel: maxFolderLevel) {
            Log.prep.warning("dzi.json cross-check mismatch: \(line, privacy: .public)")
        }
    }
}
