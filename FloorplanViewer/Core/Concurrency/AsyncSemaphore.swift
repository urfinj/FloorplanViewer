import Foundation
import os

/// Cancellation-aware counting semaphore. Caps concurrent preparation pipelines so three
/// simultaneous downloads+extractions can't spike CPU/disk.
final nonisolated class AsyncSemaphore: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        /// Available tokens.
        var permits: Int
        var waiters: [Waiter] = []
    }

    private enum Acquisition {
        case acquired
        case cancelled
        case suspended
    }

    private let state: OSAllocatedUnfairLock<State>

    init(value: Int) {
        state = OSAllocatedUnfairLock(initialState: State(permits: value))
    }

    /// Suspends until a token is available.
    func waitUnlessCancelled() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Never resume a continuation while holding the lock — decide first, act after.
                let acquisition = state.withLock { state -> Acquisition in
                    if Task.isCancelled {
                        return .cancelled
                    }
                    if state.permits > 0 {
                        state.permits -= 1
                        return .acquired
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return .suspended
                }
                switch acquisition {
                case .acquired: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .suspended: break // resumed by `signal()` or the cancellation handler
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Releases a token, waking the oldest waiter (FIFO) or incrementing the count.
    func signal() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            if state.waiters.isEmpty {
                state.permits += 1
                return nil
            }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }

    /// Runs `body` holding exactly one token, guaranteeing a matching `signal` on any exit path
    /// (return, throw, cancellation).
    func withToken<T>(_ body: () async throws -> T) async throws -> T {
        try await waitUnlessCancelled()
        defer { signal() }
        return try await body()
    }
}
