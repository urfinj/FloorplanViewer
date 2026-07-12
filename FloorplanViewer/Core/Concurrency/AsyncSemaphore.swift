import Foundation
import os

/// Cancellation-aware counting semaphore with promotable reservations. Caps concurrent
/// preparation pipelines while allowing an explicitly selected project to receive the next slot.
final nonisolated class AsyncSemaphore: Sendable {
    enum Priority: Int, Comparable, Sendable {
        case background
        case userInitiated

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct WaiterID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        init() {
            rawValue = UUID()
        }
    }

    private enum RequestState {
        case queued(CheckedContinuation<Void, any Error>?)
        case granted
    }

    private struct Request {
        var priority: Priority
        var state: RequestState
    }

    private struct State {
        var permits: Int
        /// Registration order. `grantNext` selects the first waiter at the highest priority.
        var queue: [WaiterID] = []
        var requests: [WaiterID: Request] = [:]
    }

    private enum WaitRegistration {
        case resume
        case suspended
        case missing
    }

    private struct Resumption {
        let continuation: CheckedContinuation<Void, any Error>
        let result: Result<Void, any Error>
    }

    private let state: OSAllocatedUnfairLock<State>

    init(value: Int) {
        state = OSAllocatedUnfairLock(initialState: State(permits: value))
    }

    /// Registers synchronously, before the owning task is created. This closes the enqueue race:
    /// selection can promote the reservation even if its task has not reached its first `await`.
    func register(id: WaiterID, priority: Priority = .background) {
        state.withLock { state in
            if var request = state.requests[id] {
                request.priority = max(request.priority, priority)
                state.requests[id] = request
                return
            }
            if state.permits > 0, state.queue.isEmpty {
                state.permits -= 1
                state.requests[id] = Request(priority: priority, state: .granted)
            } else {
                state.queue.append(id)
                state.requests[id] = Request(priority: priority, state: .queued(nil))
            }
        }
    }

    /// Raises a queued reservation. Running work is deliberately never preempted.
    func promote(id: WaiterID, to priority: Priority) {
        state.withLock { state in
            guard var request = state.requests[id] else { return }
            request.priority = max(request.priority, priority)
            state.requests[id] = request
        }
    }

    /// Runs `body` holding exactly one registered token. Any cancellation path removes the
    /// reservation and hands an already-granted token to the next waiter.
    func withToken<T>(
        id: WaiterID = WaiterID(),
        priority: Priority = .background,
        _ body: () async throws -> T
    ) async throws -> T {
        register(id: id, priority: priority)
        do {
            try await waitForGrant(id: id)
            try Task.checkCancellation()
        } catch {
            cancel(id: id)
            throw error
        }
        defer { finish(id: id) }
        return try await body()
    }

    private func waitForGrant(id: WaiterID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> WaitRegistration in
                    guard var request = state.requests[id] else { return .missing }
                    switch request.state {
                    case .granted:
                        return .resume
                    case .queued:
                        request.state = .queued(continuation)
                        state.requests[id] = request
                        return .suspended
                    }
                }
                switch registration {
                case .resume:
                    continuation.resume()
                case .suspended:
                    break
                case .missing:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private func finish(id: WaiterID) {
        let resumption = state.withLock { state -> Resumption? in
            guard let request = state.requests[id], case .granted = request.state else { return nil }
            state.requests[id] = nil
            return grantNext(in: &state)
        }
        resume(resumption)
    }

    private func cancel(id: WaiterID) {
        let resumptions = state.withLock { state -> [Resumption] in
            guard let request = state.requests.removeValue(forKey: id) else { return [] }
            switch request.state {
            case let .queued(continuation):
                state.queue.removeAll { $0 == id }
                guard let continuation else { return [] }
                return [Resumption(continuation: continuation, result: .failure(CancellationError()))]
            case .granted:
                return grantNext(in: &state).map { [$0] } ?? []
            }
        }
        for resumption in resumptions {
            resume(resumption)
        }
    }

    /// Grants the highest-priority reservation, preserving FIFO within equal priority.
    private func grantNext(in state: inout State) -> Resumption? {
        guard !state.queue.isEmpty else {
            state.permits += 1
            return nil
        }
        let highestPriority = state.queue.compactMap { state.requests[$0]?.priority }.max() ?? .background
        guard let index = state.queue.firstIndex(where: { state.requests[$0]?.priority == highestPriority }) else {
            state.permits += 1
            return nil
        }
        let id = state.queue.remove(at: index)
        guard var request = state.requests[id] else {
            return grantNext(in: &state)
        }
        let continuation: CheckedContinuation<Void, any Error>? = switch request.state {
        case let .queued(waitingContinuation):
            waitingContinuation
        case .granted:
            nil
        }
        request.state = .granted
        state.requests[id] = request
        guard let continuation else { return nil }
        return Resumption(continuation: continuation, result: .success(()))
    }

    private func resume(_ resumption: Resumption?) {
        guard let resumption else { return }
        resumption.continuation.resume(with: resumption.result)
    }
}
