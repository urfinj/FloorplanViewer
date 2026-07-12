import SwiftUI

/// Shown while the composition root resolves. It mirrors the real project list so the transition
/// into `RootView` changes content, not the entire screen hierarchy.
struct LaunchView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(PackageCatalog.seed, id: \.id) { project in
                    ProjectListSkeletonRow(
                        name: project.name,
                        announcesLoading: project.id == PackageCatalog.seed.first?.id
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Floorplans")
            .scrollDisabled(true)
        }
    }
}

#Preview {
    LaunchView()
}
