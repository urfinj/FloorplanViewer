import SwiftUI

/// Adds the Debug / Demo toolbar gear + its sheet to a view. Packaged as a `ViewModifier` so
/// `RootView` carries a single `.debugSettingsGear(controller:)` line and owns none of the
/// presentation state — removing the feature deletes this file and that one line.
struct DebugSettingsGear: ViewModifier {
    let controller: DebugController
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showing = true
                    } label: {
                        Label("Debug / Demo settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showing) {
                SettingsSheet(controller: controller)
                    .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    /// Attaches the Debug / Demo gear + sheet (see `DebugSettingsGear`).
    func debugSettingsGear(controller: DebugController) -> some View {
        modifier(DebugSettingsGear(controller: controller))
    }
}
