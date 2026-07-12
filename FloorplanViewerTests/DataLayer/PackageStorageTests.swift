import Foundation
import Testing
@testable import FloorplanViewer

struct PackageStorageTests {
    private func makeStorage() throws -> (PackageStorage, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "pkgstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (PackageStorage(root: root), root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func relativeAndAbsolutePathsRoundTrip() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let abs = try #require(storage.absoluteURL(for: "archives/project-1.tar.gz"))
        #expect(storage.relativePath(for: abs) == "archives/project-1.tar.gz")
    }

    @Test(arguments: ["../escape.txt", "../../etc/passwd", "archives/../../out.txt"])
    func rejectsEscapingPaths(relPath: String) throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(storage.absoluteURL(for: relPath) == nil)
    }

    @Test func promoteFileReplacesExistingTarget() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        // Existing target.
        let destRel = storage.archiveRelPath(projectID: "project-1")
        let dest = try #require(storage.absoluteURL(for: destRel))
        try write("old", to: dest)
        // Staged replacement.
        let staged = storage.stagingURL().appending(path: "new.tar.gz")
        try write("new", to: staged)

        try storage.promoteStagedFile(from: staged, toRelative: destRel)
        #expect(storage.fileExists(atRelative: destRel))
        #expect(try String(contentsOf: dest, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path)) // staged consumed
    }

    @Test func promoteDirectoryReplacesExistingTree() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let destRel = storage.extractedRelDir(projectID: "project-1")
        let dest = try #require(storage.absoluteURL(for: destRel))
        try write("stale", to: dest.appending(path: "old.txt"))

        let staged = storage.freshStagingURL(component: "extract-x")
        try write("<dzi/>", to: staged.appending(path: "tileset/floorplan.dzi"))

        try storage.promoteStagedDirectory(from: staged, toRelative: destRel)
        #expect(storage.directoryExists(atRelative: destRel))
        #expect(storage.fileExists(atRelative: "\(destRel)/tileset/floorplan.dzi"))
        #expect(!storage.fileExists(atRelative: "\(destRel)/old.txt")) // old tree gone
    }

    @Test func wipeStagingLeavesArchivesAndExtractedIntact() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: #require(storage.absoluteURL(for: storage.archiveRelPath(projectID: "project-1"))))
        try write("s", to: storage.stagingURL().appending(path: "tmp.bin"))

        try storage.wipeStaging()
        #expect(!FileManager.default.fileExists(atPath: storage.stagingURL().path))
        #expect(storage.fileExists(atRelative: storage.archiveRelPath(projectID: "project-1")))
    }
}
