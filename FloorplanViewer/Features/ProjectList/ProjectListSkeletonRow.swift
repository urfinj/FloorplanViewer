import SwiftUI

/// Matches the geometry of a real project row so launch-to-content never jumps vertically.
struct ProjectListSkeletonRow: View {
    let announcesLoading: Bool
    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: thumbnailSide, height: thumbnailSide)
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 112, height: 15)
                Capsule()
                    .fill(.quaternary)
                    .frame(maxWidth: 190)
                    .frame(height: 7)
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 104, height: 21)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .modifier(LoadingPulse())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading floorplans")
        .accessibilityHidden(!announcesLoading)
    }
}
