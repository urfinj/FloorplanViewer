#if DEBUG
    import SwiftUI

    /// Dev-only gallery of every project-row display state, for visual review without driving
    /// the real pipeline (recovery + auto-prep would rewrite staged DB states within seconds).
    /// Launch with `FLOORPLAN_DEBUG_ROW_GALLERY=1`. Same precedent as `FLOORPLAN_DEBUG_ZOOM`.
    struct DebugRowStateGallery: View {
        /// Resolves a fixture row's preview path against real on-disk packages, so the ready
        /// variant shows an actual thumbnail when one exists.
        let resolvePreview: (ProjectListRow) -> URL?

        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["FLOORPLAN_DEBUG_ROW_GALLERY"] == "1"
        }

        var body: some View {
            NavigationStack {
                List(Self.variants, id: \.caption) { variant in
                    Section(variant.caption) {
                        ProjectRowView(
                            row: variant.row,
                            previewURL: resolvePreview(variant.row),
                            isOffline: variant.isOffline
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .navigationTitle("Row states (debug)")
            }
        }

        private struct Variant {
            let caption: String
            let row: ProjectListRow
            var isOffline = false
        }

        private static let variants: [Variant] = [
            Variant(
                caption: "Queued / not prepared (online)",
                row: fixture(state: .queued)
            ),
            Variant(
                caption: "Downloading with progress",
                row: fixture(state: .downloading, progress: 0.47)
            ),
            Variant(
                caption: "Downloading, size unknown",
                row: fixture(state: .downloading)
            ),
            Variant(
                caption: "Extracting",
                row: fixture(state: .extracting)
            ),
            Variant(
                caption: "Retrying a download (attempt 3, live progress)",
                row: fixture(state: .downloading, progress: 0.62, retryCount: 2)
            ),
            Variant(
                caption: "Retrying an extraction (attempt 2)",
                row: fixture(state: .extracting, retryCount: 1)
            ),
            Variant(
                caption: "Ready — available offline",
                row: fixture(
                    state: .ready,
                    markerCount: 5,
                    extractedRelDir: "extracted/project-1",
                    lastSuccessAt: Date().timeIntervalSince1970 - 1800
                )
            ),
            Variant(
                caption: "Failed — will retry (manual Retry offered)",
                row: fixture(
                    state: .failed,
                    reason: .network,
                    retryCount: 2,
                    nextRetryAt: Date().timeIntervalSince1970 + 300
                )
            ),
            Variant(
                caption: "Never prepared while offline",
                row: fixture(state: .notPrepared),
                isOffline: true
            )
        ]

        private static func fixture(
            state: PackageState,
            progress: Double? = nil,
            reason: PackageFailureReason? = nil,
            retryCount: Int = 0,
            nextRetryAt: Double? = nil,
            markerCount: Int = 0,
            extractedRelDir: String? = nil,
            lastSuccessAt: Double? = nil
        ) -> ProjectListRow {
            ProjectListRow(
                id: "project-1",
                name: "Project 1",
                sortOrder: 0,
                stateRaw: state.rawValue,
                failureReasonRaw: reason?.rawValue,
                downloadProgress: progress,
                retryCount: retryCount,
                nextRetryAt: nextRetryAt,
                markerCount: markerCount,
                extractedRelDir: extractedRelDir,
                lastSuccessAt: lastSuccessAt
            )
        }
    }
#endif
