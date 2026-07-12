import Testing
@testable import FloorplanViewer

struct AppLaunchErrorTests {
    @Test func userMessageIsNonEmptyAndLeaksNoDetail() {
        let error = AppLaunchError.databaseOpenFailed(underlying: "/Users/secret/path.sqlite")
        #expect(!error.userMessage.isEmpty)
        #expect(!error.userMessage.contains("secret"))
    }

    @Test func casesAreEquatable() {
        #expect(AppLaunchError.databaseOpenFailed(underlying: "a") == .databaseOpenFailed(underlying: "a"))
        #expect(AppLaunchError.recoveryFailed(underlying: "a") != .databaseOpenFailed(underlying: "a"))
    }
}
