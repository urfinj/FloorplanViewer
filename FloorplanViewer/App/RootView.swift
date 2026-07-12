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
        .task { await startProjectFlow() }
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
        List(selection: $model.selectedProjectID) {
            if model.rows.isEmpty, !model.observationFailed {
                ForEach(PackageCatalog.seed, id: \.id) { project in
                    ProjectListSkeletonRow(
                        name: project.name,
                        announcesLoading: project.id == PackageCatalog.seed.first?.id
                    )
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(model.rows) { row in
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
            }
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
            FloorplanLoadingView(
                status: "Opening floorplan",
                detail: "Checking the offline package…",
                progress: nil
            )
            .navigationTitle(selectedProjectTitle)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Select a Project", systemImage: "square.stack.3d.up")
        }
    }

    private var selectedProjectTitle: String {
        guard let selectedID = model.selectedProjectID else { return "Floorplan" }
        return model.rows.first(where: { $0.id == selectedID })?.name ?? "Floorplan"
    }

    /// Establish visible rows and the reactive database stream before preparation can make its
    /// first transition. This prevents fast device pipelines from collapsing every intermediate
    /// state into a single skeleton → ready frame.
    private func startProjectFlow() async {
        await model.bootstrap()
        async let observation: Void = model.observe()
        await Task.yield() // let SwiftUI commit the initial package-state rows
        await environment.coordinator.start()
        await observation
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
