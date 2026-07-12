import Foundation
import SWCompression
import Testing
@testable import FloorplanViewer

/// The real `SWCompressionArchiveExtractor` over archives generated in-test (no committed
/// binaries): round-trip fidelity, hostile-entry guards, corrupt input, bounds.
struct ExtractorTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a `.tar.gz` from (name, data) pairs — `nil` data = directory entry. Names use the
    /// same `./` prefix as the real vips bundles.
    private func makeArchive(entries: [(name: String, data: Data?)], at url: URL) throws {
        var tarEntries: [TarEntry] = []
        for (name, data) in entries {
            var info = TarEntryInfo(name: name, type: data == nil ? .directory : .regular)
            info.permissions = Permissions(rawValue: 0o644)
            tarEntries.append(TarEntry(info: info, data: data))
        }
        let tar = TarContainer.create(from: tarEntries)
        let gz = try GzipArchive.archive(data: tar)
        try gz.write(to: url)
    }

    @Test func roundTripsSampleShapedTree() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tile = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let descriptor = Data("<Image TileSize=\"256\"/>".utf8)
        let archive = dir.appending(path: "pkg.tar.gz")
        try makeArchive(entries: [
            ("./", nil),
            ("./preview.jpg", Data([0x01])),
            ("./tileset/", nil),
            ("./tileset/floorplan.dzi", descriptor),
            ("./tileset/tiles/", nil),
            ("./tileset/tiles/4/", nil),
            ("./tileset/tiles/4/0_0.jpg", tile)
        ], at: archive)

        let out = dir.appending(path: "out")
        try await SWCompressionArchiveExtractor().extract(archiveURL: archive, into: out)

        #expect(try Data(contentsOf: out.appending(path: "tileset/floorplan.dzi")) == descriptor)
        #expect(try Data(contentsOf: out.appending(path: "tileset/tiles/4/0_0.jpg")) == tile)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "preview.jpg").path))
    }

    @Test func corruptGzipThrowsCorruptArchive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appending(path: "pkg.tar.gz")
        try makeArchive(entries: [("./a.txt", Data("hello".utf8))], at: archive)
        let bytes = try Data(contentsOf: archive)
        try bytes.prefix(bytes.count / 2).write(to: archive) // truncate

        do {
            try await SWCompressionArchiveExtractor().extract(archiveURL: archive, into: dir.appending(path: "out"))
            Issue.record("Expected corruptArchive")
        } catch let error as PreparationError {
            #expect(error.reason == .corruptArchive)
        }
    }

    @Test func hostileEntriesAreSkippedAndNothingEscapesTheRoot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appending(path: "pkg.tar.gz")
        try makeArchive(entries: [
            ("../evil.txt", Data("evil".utf8)),
            ("/abs.txt", Data("abs".utf8)),
            ("./tileset/../../escape.txt", Data("esc".utf8)),
            ("./ok.txt", Data("ok".utf8))
        ], at: archive)

        let out = dir.appending(path: "sandbox/out") // extra parent so `../` targets are checkable
        try await SWCompressionArchiveExtractor().extract(archiveURL: archive, into: out)

        #expect(FileManager.default.fileExists(atPath: out.appending(path: "ok.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "sandbox/evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "escape.txt").path))
        #expect(!FileManager.default.fileExists(atPath: "/abs.txt"))
        // Nothing but `out` inside the sandbox parent.
        let sandboxContents = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "sandbox").path)
        #expect(sandboxContents == ["out"])
    }

    @Test func symlinkEntriesAreSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appending(path: "pkg.tar.gz")
        var link = TarEntryInfo(name: "./link", type: .symbolicLink)
        link.linkName = "/etc/passwd"
        var regular = TarEntryInfo(name: "./file.txt", type: .regular)
        regular.permissions = Permissions(rawValue: 0o644)
        let tar = TarContainer.create(from: [
            TarEntry(info: link, data: nil),
            TarEntry(info: regular, data: Data("x".utf8))
        ])
        try GzipArchive.archive(data: tar).write(to: archive)

        let out = dir.appending(path: "out")
        try await SWCompressionArchiveExtractor().extract(archiveURL: archive, into: out)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "link").path))
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "file.txt").path))
    }

    @Test func entryCountBoundIsEnforced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appending(path: "pkg.tar.gz")
        try makeArchive(entries: (0 ..< 5).map { ("./f\($0).txt", Data("x".utf8)) }, at: archive)

        var extractor = SWCompressionArchiveExtractor()
        extractor.maxEntries = 4
        do {
            try await extractor.extract(archiveURL: archive, into: dir.appending(path: "out"))
            Issue.record("Expected corruptArchive for entry bound")
        } catch let error as PreparationError {
            #expect(error.reason == .corruptArchive)
        }
    }

    @Test func expandedBytesBoundIsEnforced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appending(path: "pkg.tar.gz")
        try makeArchive(entries: [("./big.bin", Data(repeating: 0, count: 64))], at: archive)

        var extractor = SWCompressionArchiveExtractor()
        extractor.maxExpandedBytes = 32
        do {
            try await extractor.extract(archiveURL: archive, into: dir.appending(path: "out"))
            Issue.record("Expected corruptArchive for byte bound")
        } catch let error as PreparationError {
            #expect(error.reason == .corruptArchive)
        }
    }
}
