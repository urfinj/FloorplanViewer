import Foundation
import SWCompression
import Testing
@testable import FloorplanViewer

/// The payoff test: the coordinator with **all real seams** (URLSession downloader over a
/// `file://` archive, SWCompression extractor, DZI validator) drives a sample-shaped package to
/// `ready` — fully offline — and recovers from a deleted extraction using the kept archive
/// without a second download.
struct PipelineIntegrationTests {
    /// A real mini DZI package: 512×512, T=256 → levels {0: 1×1, 1: 2×2}, maxLevel 1.
    private static let miniDescriptor = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Image xmlns="http://schemas.microsoft.com/deepzoom/2008" Format="jpg" Overlap="0" TileSize="256">
      <Size Height="512" Width="512"/>
    </Image>
    """

    private final class CountingDownloader: PackageDownloading, @unchecked Sendable {
        // @unchecked Sendable: counter serialized by `lock`.
        private let wrapped = URLSessionPackageDownloader()
        private let lock = NSLock()
        private var count = 0
        var calls: Int {
            lock.withLock { count }
        }

        func download(
            from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void
        ) async throws {
            lock.withLock { count += 1 }
            try await wrapped.download(from: url, to: destination, progress: progress)
        }
    }

    private func makeMiniArchive(at url: URL) throws {
        let tile = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var entries: [(String, Data?)] = [
            ("./", nil), ("./preview.jpg", tile), ("./tileset/", nil),
            ("./tileset/floorplan.dzi", Data(Self.miniDescriptor.utf8)),
            ("./tileset/tiles/", nil), ("./tileset/tiles/0/", nil), ("./tileset/tiles/1/", nil),
            ("./tileset/tiles/0/0_0.jpg", tile)
        ]
        for col in 0 ... 1 {
            for row in 0 ... 1 {
                entries.append(("./tileset/tiles/1/\(col)_\(row).jpg", tile))
            }
        }
        var tarEntries: [TarEntry] = []
        for (name, data) in entries {
            var info = TarEntryInfo(name: name, type: data == nil ? .directory : .regular)
            info.permissions = Permissions(rawValue: 0o644)
            tarEntries.append(TarEntry(info: info, data: data))
        }
        try GzipArchive.archive(data: TarContainer.create(from: tarEntries)).write(to: url)
    }

    @Test func realSeamsPrepareToReadyAndRecoverFromArchiveWithoutRedownload() async throws {
        let db = try AppDatabase.inMemory()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Point project-1's seeded URL at a real file:// archive built with the real libraries.
        let archiveURL = root.appending(path: "mini.tar.gz")
        try makeMiniArchive(at: archiveURL)
        try await db.writer.write { database in
            try database.execute(
                sql: "UPDATE project SET package_url = ? WHERE id = 'project-1'",
                arguments: [archiveURL.absoluteString]
            )
        }

        let clock = TestClock()
        let storage = PackageStorage(root: root.appending(path: "packages"))
        let packages = PackageRepository(dbWriter: db.writer, clock: clock)
        let downloader = CountingDownloader()
        let coordinator = PackagePreparationCoordinator(
            packages: packages,
            projects: ProjectRepository(dbWriter: db.writer),
            storage: storage,
            downloader: downloader,
            extractor: SWCompressionArchiveExtractor(),
            validator: DZIPackageValidator(),
            pathMonitor: StubPathMonitor(satisfied: true),
            clock: clock,
            rng: FixedRNG()
        )

        // Download → extract → validate → promote → ready, end to end, offline.
        await coordinator.prepare(projectID: "project-1")
        await coordinator.awaitQuiescence()
        let ready = try #require(try await packages.readyPackage(projectID: "project-1"))
        #expect(ready.width == 512)
        #expect(ready.maxFolderLevel == 1)
        #expect(ready.tilesRelDir.hasSuffix("tileset/tiles"))
        #expect(storage.fileExists(atRelative: "\(ready.tilesRelDir)/1/1_1.jpg"))
        #expect(downloader.calls == 1)

        // Delete the extracted tree → re-prepare recovers from the kept archive, no re-download.
        try storage.removeItem(atRelative: ready.extractedRelDir)
        await coordinator.prepare(projectID: "project-1")
        await coordinator.awaitQuiescence()
        #expect(try await packages.readyPackage(projectID: "project-1") != nil)
        #expect(downloader.calls == 1)
        await coordinator.stop()
    }
}
