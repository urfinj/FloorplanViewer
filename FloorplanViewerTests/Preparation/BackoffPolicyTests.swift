import Testing
@testable import FloorplanViewer

struct BackoffPolicyTests {
    private let policy = BackoffPolicy(base: 3, cap: 300)

    @Test(arguments: [
        (attempt: 1, expected: 1.5),
        (attempt: 2, expected: 3.0),
        (attempt: 3, expected: 6.0),
        (attempt: 4, expected: 12.0)
    ])
    func zeroJitterYieldsHalfOfCappedExponential(testCase: (attempt: Int, expected: Double)) {
        #expect(policy.delay(attempt: testCase.attempt, unitJitter: 0) == testCase.expected)
    }

    @Test func fullJitterYieldsFullCappedExponential() {
        #expect(policy.delay(attempt: 2, unitJitter: 1) == 6.0)
    }

    @Test func delayNeverExceedsCap() {
        #expect(policy.delay(attempt: 50, unitJitter: 1) == 300)
        #expect(policy.delay(attempt: 50, unitJitter: 0) == 150) // capped/2
    }

    @Test func outOfRangeJitterIsClamped() {
        #expect(policy.delay(attempt: 1, unitJitter: -3) == 1.5)
        #expect(policy.delay(attempt: 1, unitJitter: 7) == 3.0)
    }
}
