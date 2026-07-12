import SwiftUI

/// The **Debug / Demo** bottom sheet, reachable from the project-list toolbar gear: a small
/// reviewer-facing surface to force offline behaviour, pace downloads so progress is visible, and
/// hard-reset the app to a clean first run. Holds no GRDB and no actor reference — everything goes
/// through `DebugController`.
struct SettingsSheet: View {
    @Bindable var controller: DebugController

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                connectivitySection
                resetSection
            }
            .navigationTitle("Debug / Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectivitySection: some View {
        Section {
            Toggle("Simulate offline", isOn: $controller.simulateOffline)
            Toggle("Slow downloads", isOn: $controller.slowDownloads)
            LabeledContent("Real network") {
                Text(controller.realIsOffline ? "Offline" : "Online")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connectivity")
        } footer: {
            Text("Slow downloads pace the transfer so the progress bar is visible — real bytes, not a mock.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Clear and reset", role: .destructive) {
                Task { await controller.clearAndReset() }
            }
        } footer: {
            Text(
                "Erases all downloads, markers, and project state, then closes the app. Reopen it for a clean first run."
            )
        }
    }
}
