import Foundation

/// Drives the project list: live rows, selection persistence/restore, and the selection →
/// prepare trigger. Views own it via `@State`; observation starts in `.task` and dies with it.
@MainActor
@Observable
final class ProjectListModel {
    private let projects: ProjectRepository
    private let appState: AppStateRepository
    private let preparation: any PreparationTriggering

    private(set) var rows: [ProjectListRow] = []
    private(set) var observationFailed = false
    private var selectionTask: Task<Void, Never>?

    var selectedProjectID: String? {
        didSet {
            selectionTask?.cancel()
            guard oldValue != selectedProjectID else { return }
            let id = selectedProjectID
            selectionTask = Task { [appState, preparation] in
                do {
                    try Task.checkCancellation()
                    try await appState.setLastSelectedProjectID(id)
                    try Task.checkCancellation()
                } catch {
                    if error is CancellationError {
                        return
                    }
                    Log.app.error("Persisting selection failed: \(String(describing: error), privacy: .public)")
                }
                guard !Task.isCancelled else { return }
                guard let id else { return }
                // Assignment trigger: preparing is retried when the project is selected.
                await preparation.projectSelected(projectID: id)
            }
        }
    }

    init(projects: ProjectRepository, appState: AppStateRepository, preparation: any PreparationTriggering) {
        self.projects = projects
        self.appState = appState
        self.preparation = preparation
    }

    /// Restores a persisted selection, if one exists, and then observes the list until the owning
    /// view goes away. Call from `.task`.
    func start() async {
        async let selectionRestore: Void = restoreSelection()
        await loadInitialRows()
        await selectionRestore
        await observe()
    }

    func retryNow(projectID: String) {
        Task { [preparation] in
            await preparation.retryNow(projectID: projectID)
        }
    }

    /// Records that the user intentionally navigated back to the project list. A subsequent
    /// launch must restore the list rather than reopening the previously viewed project.
    func showProjectList() {
        selectedProjectID = nil
    }

    /// Re-subscribe after an observation failure.
    func retryObservation() {
        observationFailed = false
        Task { await observe() }
    }

    /// Restores only a **previously persisted** selection. A virgin launch selects nothing —
    /// the assignment flow starts at the project list (iPhone shows the list; iPad shows the
    /// "Select a Project" placeholder).
    private func restoreSelection() async {
        do {
            let known = try await projects.fetchAll().map(\.id)
            let persisted = try await appState.lastSelectedProjectID()
            if let persisted, known.contains(persisted) {
                selectedProjectID = persisted
            }
        } catch {
            Log.app.error("Restoring selection failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Do not make first paint wait for the reactive stream's initial emission while the
    /// preparation coordinator is also writing launch transitions. The seeded rows already hold
    /// meaningful per-project states; observation takes over immediately after this snapshot.
    private func loadInitialRows() async {
        do {
            rows = try await projects.fetchProjectList()
        } catch {
            if error is CancellationError || Task.isCancelled {
                return
            }
            Log.app.error("Initial project snapshot failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func observe() async {
        do {
            for try await snapshot in projects.observeProjectList() {
                rows = snapshot
            }
        } catch {
            Log.app.error("Project list observation failed: \(String(describing: error), privacy: .public)")
            observationFailed = true
        }
    }
}
