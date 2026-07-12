import Foundation

/// Capped exponential backoff with equal jitter. Attempt 1 → ~base, doubling per attempt, never
/// above `cap`. `unitJitter` ∈ 0…1 is injected so tests are deterministic.
nonisolated struct BackoffPolicy: Sendable {
    var base: TimeInterval = 3
    var cap: TimeInterval = 300 // 5 minutes

    func delay(attempt: Int, unitJitter: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let capped = min(base * pow(2, exponent), cap)
        let half = capped / 2
        let clampedJitter = min(max(unitJitter, 0), 1)
        return min(half + clampedJitter * half, cap)
    }
}
