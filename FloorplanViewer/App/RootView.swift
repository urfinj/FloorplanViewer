import SwiftUI

/// The app's navigation surface: sidebar of projects (collapses to a stack on iPhone), detail =
/// the selected project's floorplan pane. Selection persists and restores; the engine starts
/// here and re-drains on foregrounding.
struct RootView: View {
    let environment: AppEnvironment

    @State private var model: ProjectListModel
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ProjectListModel(
            projects: environment.projectRepository,
            appState: environment.appStateRepository,
            preparation: environment.coordinator
        ))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            await environment.coordinator.start()
        }
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.coordinator.prepareAll() }
        }
    }

    private var sidebar: some View {
        List(model.rows, selection: $model.selectedProjectID) { row in
            ProjectRowView(row: row, isOffline: environment.connectivity.isOffline) {
                model.retryNow(projectID: row.id)
            }
            .tag(row.id)
        }
        .navigationTitle("Floorplans")
        .overlay {
            if model.observationFailed {
                ContentUnavailableView {
                    Label("Couldn’t Load Projects", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") { model.retryObservation() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.rows.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID = model.selectedProjectID {
            FloorplanViewerScreen(model: environment.makeViewerModel(projectID: selectedID))
                .id(selectedID) // fresh model + viewer per project; no cross-project bleed
        } else {
            ContentUnavailableView("Select a Project", systemImage: "square.stack.3d.up")
        }
    }
}
