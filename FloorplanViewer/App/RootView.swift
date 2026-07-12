import SwiftUI

/// Placeholder root shell. Phase 5 replaces this with the `NavigationSplitView` project list.
struct RootView: View {
    let environment: AppEnvironment

    #if DEBUG
        @State private var showSpike = false
    #endif

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Projects",
                systemImage: "square.stack.3d.up",
                description: Text("The project list and floorplan viewer arrive in later phases.")
            )
            .navigationTitle("Floorplans")
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
}
