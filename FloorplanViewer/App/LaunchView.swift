import SwiftUI

/// Shown while the composition root resolves. It mirrors the real project list so the transition
/// into `RootView` changes content, not the entire screen hierarchy.
struct LaunchView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(0 ..< 3, id: \.self) { index in
                    ProjectListSkeletonRow(announcesLoading: index == 0)
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
