import Foundation
@testable import FloorplanViewer

/// Deterministic RNG for exact backoff assertions (`next() == 0` → zero jitter).
nonisolated struct FixedRNG: RandomNumberGenerator, Sendable {
    var value: UInt64 = 0
    mutating func next() -> UInt64 {
        value
    }
}

/// Scriptable downloader: one behavior per call; the last behavior repeats when exhausted.
final class MockDownloader: PackageDownloading, @unchecked Sendable {
    /// @unchecked Sendable: state serialized by `lock`.
    enum Behavior {
        case success(bytes: Int = 128, ticks: [Double] = [0.5, 1.0])
        case failure(PreparationError)
        case hangUntilCancelled
    }

    private let lock = NSLock()
    private var script: [Behavior]
    private var callCount = 0

    init(script: [Behavior] = [.success()]) {
        self.script = script
    }

    var calls: Int {
        lock.withLock { callCount }
    }

    func download(
        from _: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws {
        let behavior = lock.withLock {
            callCount += 1
            return script.indices.contains(callCount - 1) ? script[callCount - 1] : (script.last ?? .success())
        }
        switch behavior {
        case let .success(bytes, ticks):
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0xAB, count: bytes).write(to: destination)
            for tick in ticks {
                await progress(tick)
            }
        case let .failure(error):
            throw error
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

/// Holds each transfer until the test releases it and records the package start order. This makes
/// coordinator priority tests deterministic without introducing real network timing.
final class GatedDownloader: PackageDownloading, Sendable {
    actor Gate {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, any Error>
        }

        private var started: [String] = []
        private var waiters: [Waiter] = []

        func wait(for packageName: String) async throws {
            let id = UUID()
            started.append(packageName)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        func releaseNext() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().continuation.resume()
        }

        func startedPackages() -> [String] {
            started
        }

        private func cancel(id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    let gate = Gate()

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws {
        try await gate.wait(for: url.lastPathComponent)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: 128).write(to: destination)
        await progress(1)
    }
}

/// Scriptable extractor. Success builds a sample-shaped tree (descriptor + max-level probe tile)
/// so the promoted package passes the readiness file checks.
final class MockExtractor: ArchiveExtracting, @unchecked Sendable {
    /// @unchecked Sendable: state serialized by `lock`.
    enum Behavior {
        case success
        case failure(PreparationError)
        case hangUntilCancelled
    }

    private let lock = NSLock()
    private var script: [Behavior]
    private var callCount = 0

    init(script: [Behavior] = [.success]) {
        self.script = script
    }

    var calls: Int {
        lock.withLock { callCount }
    }

    func extract(archiveURL _: URL, into directory: URL) async throws {
        let behavior = lock.withLock {
            callCount += 1
            return script.indices.contains(callCount - 1) ? script[callCount - 1] : (script.last ?? .success)
        }
        switch behavior {
        case .success:
            try Self.buildSampleTree(in: directory)
        case let .failure(error):
            throw error
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Mirrors the real package shape for the `.sample` layout (3300×2552, T=256, M=4): descriptor
    /// plus both corner probe tiles of the full-resolution level (grid 13×10 → `0_0` and `12_9`).
    static func buildSampleTree(in root: URL) throws {
        let tiles = root.appending(path: "tileset/tiles/4")
        try FileManager.default.createDirectory(at: tiles, withIntermediateDirectories: true)
        try Data("<Image/>".utf8).write(to: root.appending(path: "tileset/floorplan.dzi"))
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tiles.appending(path: "0_0.jpg"))
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tiles.appending(path: "12_9.jpg"))
    }
}

/// Scriptable validator.
final class MockValidator: PackageValidating, @unchecked Sendable {
    /// @unchecked Sendable: state serialized by `lock`.
    enum Behavior {
        case success(ValidatedPackageLayout)
        case failure(PreparationError)
    }

    private let lock = NSLock()
    private var script: [Behavior]
    private var callCount = 0

    init(script: [Behavior] = [.success(.sample)]) {
        self.script = script
    }

    var calls: Int {
        lock.withLock { callCount }
    }

    func validate(extractedDir _: URL) async throws -> ValidatedPackageLayout {
        let behavior = lock.withLock {
            callCount += 1
            return script.indices.contains(callCount - 1) ? script[callCount - 1] : (script.last ?? .success(.sample))
        }
        switch behavior {
        case let .success(layout): return layout
        case let .failure(error): throw error
        }
    }
}

nonisolated extension ValidatedPackageLayout {
    /// Matches `MockExtractor.buildSampleTree` and the real sample-1 descriptor values.
    static let sample = ValidatedPackageLayout(
        descriptorRelPath: "tileset/floorplan.dzi",
        tilesRelDir: "tileset/tiles",
        width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg", maxFolderLevel: 4
    )
}
