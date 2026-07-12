import Foundation

/// Transfer seam. Streams the archive at `url` to `destination`, reporting raw progress ticks
/// (`nil` = total size unknown / indeterminate); the caller throttles persistence.
/// Implementations throw `PreparationError` for classified failures and rethrow
/// `CancellationError` untouched.
nonisolated protocol PackageDownloading: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws
}
