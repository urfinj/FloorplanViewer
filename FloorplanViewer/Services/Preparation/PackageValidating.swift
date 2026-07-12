import Foundation

/// What validation proved about an extracted package, with paths **relative to the extracted
/// directory** (the coordinator rebases them onto the promoted location). Plain values so the
/// seam has no dependency on the DZI layer's types.
nonisolated struct ValidatedPackageLayout: Sendable, Equatable {
    let descriptorRelPath: String
    let tilesRelDir: String
    let width: Int
    let height: Int
    let tileSize: Int
    let overlap: Int
    let format: String
    let maxFolderLevel: Int
}

/// Validation seam. Locates the descriptor, parses it, verifies the tile hierarchy (contiguous
/// levels, probe tiles) — all **in staging, before promotion**. Throws `PreparationError` with
/// `.descriptorNotFound` / `.descriptorInvalid` / `.tilesMissing`.
nonisolated protocol PackageValidating: Sendable {
    func validate(extractedDir: URL) async throws -> ValidatedPackageLayout
}
