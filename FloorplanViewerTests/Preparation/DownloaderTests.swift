import Foundation
import Testing
@testable import FloorplanViewer

/// The real `URLSessionPackageDownloader` against `file://` fixtures — same code path as HTTP
/// minus the status check, fully offline.
struct DownloaderTests {
    private final nonisolated class TickBox: @unchecked Sendable {
        // @unchecked Sendable: appends serialized by `lock`.
        private let lock = NSLock()
        private var values: [Double?] = []
        func append(_ value: Double?) {
            lock.withLock { values.append(value) }
        }

        var all: [Double?] {
            lock.withLock { values }
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func downloadsFixtureByteIdenticalWithMonotonicProgress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "fixture.bin")
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let destination = dir.appending(path: "out/downloaded.bin")

        let ticks = TickBox()
        try await URLSessionPackageDownloader().download(from: source, to: destination) { ticks.append($0) }

        #expect(try Data(contentsOf: destination) == payload)
        let fractions = ticks.all.compactMap(\.self)
        #expect(fractions.last == 1.0)
        #expect(fractions == fractions.sorted()) // monotonic
    }

    @Test func missingSourceThrowsMappedErrorAndLeavesNoFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appending(path: "out.bin")
        let missing = dir.appending(path: "nope.bin")

        await #expect(throws: PreparationError.self) {
            try await URLSessionPackageDownloader().download(from: missing, to: destination) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func emptySourceIsRejectedAsCorrupt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "empty.bin")
        try Data().write(to: source)
        let destination = dir.appending(path: "out.bin")

        do {
            try await URLSessionPackageDownloader().download(from: source, to: destination) { _ in }
            Issue.record("Expected corruptArchive for an empty download")
        } catch let error as PreparationError {
            #expect(error.reason == .corruptArchive)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
