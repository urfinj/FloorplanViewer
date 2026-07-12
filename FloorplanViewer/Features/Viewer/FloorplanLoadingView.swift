import SwiftUI

/// One stable loading surface for viewer creation, download, extraction, and tiled-canvas open.
/// The abstract plan skeleton cannot be mistaken for the package's `preview.jpg`.
struct FloorplanLoadingView: View {
    let status: String
    let detail: String
    let progress: Double?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let layout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(spacing: 24))
            : AnyLayout(VStackLayout(spacing: 24))

        layout {
            planSkeleton
            statusBlock
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statusBlock: some View {
        VStack(spacing: 10) {
            progressIndicator
            Text(status)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
    }

    private var planSkeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary)
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    skeletonRoom
                    skeletonRoom
                        .frame(maxHeight: 64)
                }
                VStack(spacing: 10) {
                    skeletonRoom
                        .frame(maxHeight: 72)
                    HStack(spacing: 10) {
                        skeletonRoom
                        skeletonRoom
                    }
                }
            }
            .padding(18)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(maxWidth: verticalSizeClass == .compact ? 280 : 420)
        .modifier(LoadingPulse())
        .accessibilityHidden(true)
    }

    private var skeletonRoom: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.background.opacity(0.9))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.12), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let progress {
            ProgressView(value: progress) {
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
            .progressViewStyle(.linear)
        } else {
            ProgressView()
                .controlSize(.regular)
        }
    }
}
