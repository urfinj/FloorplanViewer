import Foundation
import Testing
@testable import FloorplanViewer

@MainActor
struct ProjectListModelTests {
    private final class SpyPreparation: PreparationTriggering, @unchecked Sendable {
        // @unchecked Sendable: state serialized by `lock`.
        private let lock = NSLock()
        private var preparedIDs: [String] = []
        var prepared: [String] {
            lock.withLock { preparedIDs }
        }

        func prepare(projectID: String) async {
            lock.withLock { preparedIDs.append(projectID) }
        }

        func retryNow(projectID: String) async {
            lock.withLock { preparedIDs.append("retry:\(projectID)") }
        }

        func prepareAll() async {}

        func packageForViewing(projectID _: String) async throws -> ReadyPackage? {
            nil
        }
    }

    private func makeModel() throws -> (ProjectListModel, AppStateRepository, SpyPreparation) {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let appState = AppStateRepository(dbWriter: db.writer, clock: clock)
        let spy = SpyPreparation()
        let model = ProjectListModel(
            projects: ProjectRepository(dbWriter: db.writer),
            appState: appState,
            preparation: spy
        )
        return (model, appState, spy)
    }

    @Test func selectionPersistsAndTriggersPrepare() async throws {
        let (model, appState, spy) = try makeModel()
        model.selectedProjectID = "project-2"
        let persisted = await eventually {
            let stored = try? await appState.lastSelectedProjectID()
            return stored == "project-2" && spy.prepared.contains("project-2")
        }
        #expect(persisted)
    }

    @Test func virginLaunchSelectsNothingSoTheListShowsFirst() async throws {
        let (model, _, spy) = try makeModel()
        // Nothing persisted → no auto-selection (assignment flow starts at the project list).
        let observing = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.selectedProjectID == nil)
        #expect(spy.prepared.isEmpty)
        observing.cancel()
    }

    @Test func restoreHonorsPersistedSelection() async throws {
        let (model, appState, _) = try makeModel()
        try await appState.setLastSelectedProjectID("project-3")
        Task { await model.start() }
        let restored = await eventually { model.selectedProjectID == "project-3" }
        #expect(restored)
    }
}
