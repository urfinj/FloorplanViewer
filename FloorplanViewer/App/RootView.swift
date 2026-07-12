import SwiftUI

/// Placeholder root shell. Phase 5 replaces this with the `NavigationSplitView` project list;
/// for now it proves the seeded projects load through the repository (no GRDB in the view).
struct RootView: View {
    let environment: AppEnvironment

    @State private var projects: [Project] = []
    #if DEBUG
        @State private var showSpike = false
    #endif

    var body: some View {
        NavigationStack {
            List(projects) { project in
                LabeledContent(project.name, value: project.id)
            }
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "square.stack.3d.up")
                }
            }
            .navigationTitle("Floorplans")
            .task { await load() }
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
    }

    private func load() async {
        do {
            projects = try await environment.projectRepository.fetchAll()
        } catch {
            Log.app.error("Loading projects failed: \(String(describing: error), privacy: .public)")
        }
    }
}
