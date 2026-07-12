import SwiftUI

/// The app's navigation surface: sidebar of projects (collapses to a stack on iPhone), detail =
/// the selected project's floorplan pane. Selection persists and restores; the engine starts
/// here and re-drains on foregrounding.
struct RootView: View {
    let environment: AppEnvironment

    @State private var model: ProjectListModel
    @State private var connectivity: ConnectivityState
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
        @State private var showSpike = false
    #endif

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ProjectListModel(
            projects: environment.projectRepository,
            appState: environment.appStateRepository,
            preparation: environment.coordinator
        ))
        _connectivity = State(initialValue: ConnectivityState(monitor: environment.pathMonitor))
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
            ProjectRowView(row: row, isOffline: connectivity.isOffline) {
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
        #if DEBUG
        .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tiling Spike", systemImage: "square.grid.3x3") { showSpike = true }
                }
            }
            .sheet(isPresented: $showSpike) {
                SpikeTiledScreen()
            }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = model.rows.first(where: { $0.id == model.selectedProjectID }) {
            FloorplanViewerScreen(row: selected, isOffline: connectivity.isOffline) {
                model.retryNow(projectID: selected.id)
            }
        } else {
            ContentUnavailableView("Select a Project", systemImage: "square.stack.3d.up")
        }
    }
}
