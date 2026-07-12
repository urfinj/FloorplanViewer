import Foundation
import Testing
@testable import FloorplanViewer

/// Selection surface the marker inspector sheet is built on: creation-order numbering, the
/// selected-marker read the `sheet(item:)` binding presents, and the immediate deselect on delete
/// that dismisses the sheet.
struct ViewerSelectionTests {
    private struct StubPreparation: PreparationTriggering {
        func prepare(projectID _: String) async {}
        func retryNow(projectID _: String) async {}
        func prepareAll() async {}
        func packageForViewing(projectID _: String) async throws -> ReadyPackage? {
            nil
        }
    }

    @Test func markerOrderAndSelectionFeedTheInspector() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let markerRepo = MarkerRepository(dbWriter: db.writer, clock: clock)
        let first = try await markerRepo.insert(projectID: "project-1", normalizedX: 0.2, normalizedY: 0.2)
        clock.advance(by: 1) // distinct created_at → stable creation order
        let second = try await markerRepo.insert(projectID: "project-1", normalizedX: 0.8, normalizedY: 0.8)

        let model = ViewerViewModel(
            projectID: "project-1",
            packages: PackageRepository(dbWriter: db.writer, clock: clock),
            markerRepository: markerRepo,
            preparation: StubPreparation(),
            connectivity: ConnectivityState(monitor: StubPathMonitor(satisfied: true)),
            storage: PackageStorage(root: FileManager.default.temporaryDirectory)
        )
        let observation = Task { await model.observeMarkers() }
        defer { observation.cancel() }
        #expect(await eventually { model.markers.count == 2 })

        #expect(model.markerNumber(for: first) == 1)
        #expect(model.markerNumber(for: second) == 2)
        #expect(model.selectedMarker == nil)

        model.toggleSelection(of: second.id)
        #expect(model.selectedMarker?.id == second.id)

        // Delete clears the selection synchronously (the sheet dismisses at once), then the row
        // disappears from the observed snapshot.
        model.deleteSelectedMarker()
        #expect(model.selectedMarker == nil)
        #expect(await eventually { model.markers.count == 1 })
        #expect(model.markerNumber(for: first) == 1)
    }
}
