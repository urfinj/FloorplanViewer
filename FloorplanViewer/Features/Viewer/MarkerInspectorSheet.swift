import SwiftUI

/// Selection/action surface for a marker: which pin it is, the normalized coordinates that are the
/// stored source of truth, and two full-width stacked actions — Delete (primary, destructive) over
/// Cancel (secondary). A low-detent sheet that leaves the map interactive behind it, so the
/// selected pin stays visible while its inspector is open.
struct MarkerInspectorSheet: View {
    let marker: Marker
    let number: Int
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            coordinateCard
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(340), .medium])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
    }

    private var header: some View {
        Text("Marker \(number)")
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Normalized `0…1` readout, one axis per row — exactly the persisted form, so the UI shows
    /// what survives zoom, screen size, project switching, and relaunch.
    private var coordinateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Normalized position")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                coordinateRow("X", value: marker.normalizedX)
                Divider()
                coordinateRow("Y", value: marker.normalizedY)
            }
            .padding(.horizontal, 16)
            .background(.quaternary, in: .rect(cornerRadius: 14))
        }
    }

    private func coordinateRow(_ label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.formatted(.number.precision(.fractionLength(3))))
                .monospacedDigit()
        }
        .font(.body)
        .padding(.vertical, 12)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Marker", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(prominent: true)
            .tint(.red)

            Button(action: onClose) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(prominent: false)
        }
        .controlSize(.large)
    }
}

private extension View {
    /// Liquid Glass button style on iOS 26+, classic bordered fallback on the iOS 17 floor —
    /// `.glass*` styles don't exist below 26, so the deployment target forces an availability gate.
    @ViewBuilder
    func adaptiveGlassButton(prominent: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}
