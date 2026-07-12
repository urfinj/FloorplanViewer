import SwiftUI

/// Adds the Debug / Demo toolbar gear + its sheet to a view. Packaged as a `ViewModifier` so
/// `RootView` carries a single `.debugSettingsGear(controller:)` line and owns none of the
/// presentation state — removing the feature deletes this file and that one line.
struct DebugSettingsGear: ViewModifier {
    let controller: DebugController
    @State private var showing = false
    /// Opens expanded; reset on each present so a prior drag to `.medium` doesn't stick.
    @State private var detent: PresentationDetent = .large

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        detent = .large
                        showing = true
                    } label: {
                        Label("Debug / Demo settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showing) {
                SettingsSheet(controller: controller)
                    .presentationDetents([.medium, .large], selection: $detent)
            }
    }
}

extension View {
    /// Attaches the Debug / Demo gear + sheet (see `DebugSettingsGear`). DEBUG-only: in a release
    /// build this is a no-op, so the panel has no entry point and the toolbar carries no gear.
    func debugSettingsGear(controller: DebugController) -> some View {
        #if DEBUG
            modifier(DebugSettingsGear(controller: controller))
        #else
            self
        #endif
    }
}
