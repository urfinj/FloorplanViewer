import Foundation

/// Production transfer: `URLSession.bytes(from:)` streamed to `destination` in buffered chunks.
/// Structured-concurrency native — cancellation propagates through the byte stream; no delegate
/// or continuation bridging. Non-HTTP responses (e.g. `file://` fixtures in tests) skip the
/// status check and exercise the same streaming path.
nonisolated struct URLSessionPackageDownloader: PackageDownloading {
    var session: URLSession = .shared
    /// Buffered write size — byte-wise `FileHandle` writes would be pathological.
    private static let chunkSize = 64 * 1024

    @concurrent
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
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
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PreparationError(reason: .httpStatus)
        }
        let expected = response.expectedContentLength // -1 when unknown
        if expected <= 0 {
            progress(nil)
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
                    progress(Double(received) / Double(expected))
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
        progress(1.0)
    }
}
