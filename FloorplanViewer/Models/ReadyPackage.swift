import Foundation

/// A validated, ready-to-render package: the viewer's only input. Constructed by
/// `PackageRepository.readyPackage(projectID:)` **only** when the row is `ready` and every
/// readiness column is present — a partially populated row can never produce one, so the viewer
/// never renders half-prepared state.
nonisolated struct ReadyPackage: Sendable, Equatable {
    let projectID: String
    let extractedRelDir: String
    let descriptorRelPath: String
    let tilesRelDir: String
    let width: Int
    let height: Int
    let tileSize: Int
    let overlap: Int
    let format: String
    let maxFolderLevel: Int
}
