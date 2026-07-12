import Foundation

/// Production transfer: `URLSession.bytes(from:)` streamed to `destination` in buffered chunks.
/// Structured-concurrency native — cancellation propagates through the byte stream; no delegate
/// or continuation bridging. Non-HTTP responses (e.g. `file://` fixtures in tests) skip the
/// status check and exercise the same streaming path.
nonisolated struct URLSessionPackageDownloader: PackageDownloading {
    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        // The 30s request timeout is the stall detector; the resource timeout is only a safety
        // net and must not kill slow-but-progressing transfers (samples are <1 MB; real packages
        // may not be).
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    var session: URLSession
    /// Optional pacing hook invoked after each chunk write. Injected only by the Debug / Demo
    /// "Slow downloads" toggle; `nil` in the production defaults and every test → the byte path is
    /// unchanged. The downloader knows nothing about the debug module — just a generic closure.
    let interChunkPause: (@Sendable () async throws -> Void)?
    /// Buffered write size — byte-wise `FileHandle` writes would be pathological.
    private static let chunkSize = 64 * 1024

    init(
        session: URLSession = Self.liveSession,
        interChunkPause: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        self.interChunkPause = interChunkPause
    }

    @concurrent
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws {
        do {
            try await stream(from: url, to: destination, progress: progress)
        } catch {
            // The partial is useless — remove it so no caller can mistake it for a completed file.
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError {
                throw error
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw PreparationError.classify(error)
        }
    }

    private func stream(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            // The persisted reason stays coarse (`httpStatus`), but 404 vs 500 vs 403 matters
            // when diagnosing in the field — keep the code in the log.
            Log.prep.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public)")
            throw PreparationError(reason: .httpStatus)
        }
        let expected = response.expectedContentLength // -1 when unknown
        if expected <= 0 {
            await progress(nil)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw PreparationError(reason: .diskFull)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: Self.chunkSize)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.chunkSize {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    await progress(Double(received) / Double(expected))
                }
                if let interChunkPause {
                    // Optional pacing (Debug / Demo "Slow downloads"). Rethrows `CancellationError`
                    // (never `try?`) so a cancelled transfer still tears down cleanly.
                    try await interChunkPause()
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        // Completed-file sanity: non-empty, and matching Content-Length when the server gave one.
        guard received > 0 else { throw PreparationError(reason: .corruptArchive) }
        if expected > 0, received != expected {
            throw PreparationError(reason: .corruptArchive)
        }
        await progress(1.0)
    }
}
