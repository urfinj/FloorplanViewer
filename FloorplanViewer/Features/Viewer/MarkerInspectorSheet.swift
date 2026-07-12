import SwiftUI

/// The selection/action surface for a marker: its number, the normalized coordinates that are the
/// stored source of truth, and Delete / Close. Presented as a low-detent sheet that leaves the map
/// interactive behind it, so the selected pin stays visible while its inspector is open; the
/// `.medium` detent is the escape hatch for large Dynamic Type sizes.
struct MarkerInspectorSheet: View {
    let marker: Marker
    let number: Int
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Marker \(number)")
                    .font(.headline)
                Spacer()
                Text("Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
            LabeledContent("Coordinates") {
                Text(coordinateText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.height(200), .medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(200)))
        .presentationDragIndicator(.visible)
    }

    /// Normalized `0…1` readout — exactly the persisted form, so the UI shows what survives
    /// zoom, screen size, and relaunch.
    private var coordinateText: String {
        let x = marker.normalizedX.formatted(.number.precision(.fractionLength(3)))
        let y = marker.normalizedY.formatted(.number.precision(.fractionLength(3)))
        return "x \(x)  ·  y \(y)"
    }
}
