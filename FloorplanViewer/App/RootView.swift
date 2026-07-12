import SwiftUI

/// The app's navigation surface: sidebar of projects (collapses to a stack on iPhone), detail =
/// the selected project's floorplan pane. Selection persists and restores; the engine starts
/// here and re-drains on foregrounding.
struct RootView: View {
    let environment: AppEnvironment

    @State private var model: ProjectListModel
    /// The selected viewer session belongs to the always-mounted navigation root, not to the
    /// transient compact detail. iOS 26/27 can keep/reuse a collapsed `NavigationSplitView`
    /// detail after Back without reliably restarting detail-scoped `.task` modifiers.
    @State private var viewerModel: ViewerViewModel?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ProjectListModel(
            projects: environment.projectRepository,
            appState: environment.appStateRepository,
            preparation: environment.coordinator
        ))
        _viewerModel = State(initialValue: nil)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
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
        .task(id: model.selectedProjectID) {
            await observeSelectedViewer()
        }
        .onChange(of: model.selectedProjectID) { _, selectedID in
            preferredCompactColumn = selectedID == nil ? .sidebar : .detail
        }
        .onChange(of: preferredCompactColumn) { _, column in
            guard column == .sidebar, model.selectedProjectID != nil else { return }
            model.showProjectList()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.coordinator.prepareAll() }
        }
    }

    private var sidebar: some View {
        List(model.rows, selection: $model.selectedProjectID) { row in
            ProjectRowView(
                row: row,
                previewURL: previewURL(for: row),
                isOffline: environment.connectivity.isOffline
            ) {
                model.retryNow(projectID: row.id)
            }
            .tag(row.id)
            .listRowSeparator(.hidden)
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

    /// Container-relative → absolute resolution happens here so the row stays storage-agnostic.
    private func previewURL(for row: ProjectListRow) -> URL? {
        row.previewRelPath.flatMap { environment.storage.absoluteURL(for: $0) }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID = model.selectedProjectID,
           let viewerModel,
           viewerModel.projectID == selectedID
        {
            FloorplanViewerScreen(
                title: model.rows.first(where: { $0.id == selectedID })?.name ?? "Floorplan",
                model: viewerModel
            )
            .id(selectedID) // fresh model + viewer per project; no cross-project bleed
        } else if model.selectedProjectID != nil {
            ProgressView()
                .controlSize(.large)
        } else {
            ContentUnavailableView("Select a Project", systemImage: "square.stack.3d.up")
        }
    }

    /// Runs above the compact detail lifecycle. Structured child observations are cancelled when
    /// selection genuinely changes, but navigating Back while selection is retained leaves the
    /// ready viewer session intact.
    private func observeSelectedViewer() async {
        guard let selectedID = model.selectedProjectID else {
            viewerModel = nil
            return
        }
        let viewer = environment.makeViewerModel(projectID: selectedID)
        viewerModel = viewer
        async let packageObservation: Void = viewer.observePackage()
        async let markerObservation: Void = viewer.observeMarkers()
        _ = await (packageObservation, markerObservation)
    }
}
