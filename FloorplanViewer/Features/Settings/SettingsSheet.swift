import SwiftUI

/// The **Debug / Demo** bottom sheet, reachable from the project-list toolbar gear: a small
/// reviewer-facing surface to force offline behaviour, pace downloads so progress is visible, and
/// hard-reset the app to a clean first run. Holds no GRDB and no actor reference — everything goes
/// through `DebugController`.
struct SettingsSheet: View {
    @Bindable var controller: DebugController

    @Environment(\.dismiss) private var dismiss
    @State private var showingClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                connectivitySection
                demoSection
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

    private var demoSection: some View {
        Section {
            Button("Seed 404 plan") {
                Task { await controller.seed404Plan() }
            }
        } header: {
            Text("Demo data")
        } footer: {
            Text("""
            Adds one project whose download 404s, so the failure and retry states are visible. \
            Upload a valid archive to \(controller.seed404URL) to make it succeed.
            """)
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset") {
                controller.reset()
            }
            Button("Clear data and reset", role: .destructive) {
                showingClearConfirm = true
            }
        } footer: {
            Text("""
            Reset restarts the app and keeps your data. Clear data and reset also erases all \
            downloads, markers, and project state first. Both close the app — reopen to continue; \
            the connectivity switches are kept.
            """)
        }
        .confirmationDialog(
            "Clear all data and reset?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase everything", role: .destructive) {
                Task { await controller.clearDataAndReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently erases all downloads, project state, and your markers, then closes the app. This can’t be undone."
            )
        }
    }
}
