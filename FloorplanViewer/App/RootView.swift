import SwiftUI

/// Interim root: live project list driven by observation, engine started from `.task`.
/// Phase 5 replaces this with the full `NavigationSplitView` + styled rows; the plumbing
/// (observation, coordinator start) carries over unchanged.
struct RootView: View {
    let environment: AppEnvironment

    @State private var rows: [ProjectListRow] = []
    #if DEBUG
        @State private var showSpike = false
    #endif

    var body: some View {
        NavigationStack {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                    Text(statusLine(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "square.stack.3d.up")
                }
            }
            .navigationTitle("Floorplans")
            .task { await start() }
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

    private func statusLine(for row: ProjectListRow) -> String {
        var line = row.state.rawValue
        if let progress = row.downloadProgress, row.state == .downloading {
            line += " \(Int(progress * 100))%"
        }
        if let reason = row.failureReason {
            line += " (\(reason.rawValue))"
        }
        return line
    }

    private func start() async {
        await environment.coordinator.start()
        do {
            for try await snapshot in environment.projectRepository.observeProjectList() {
                rows = snapshot
            }
        } catch {
            Log.app.error("Project list observation failed: \(String(describing: error), privacy: .public)")
        }
    }
}
