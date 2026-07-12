import CoreGraphics
import Foundation

/// Everything the renderer needs for one ready package. Built exclusively from the awaited
/// `packageForViewing` handshake — never from an unverified row.
@MainActor
struct ViewerContent {
    let pyramid: TilePyramid
    let provider: TileProvider

    var imageSize: CGSize {
        pyramid.fullSize
    }
}

/// Drives one project's floorplan pane: live package state, the awaited viewer-entry handshake,
/// and marker interactions. One instance per selected project (`.id(projectID)` on the screen).
@MainActor
@Observable
final class ViewerViewModel {
    let projectID: String
    private let packages: PackageRepository
    private let markerRepository: MarkerRepository
    private let preparation: any PreparationTriggering
    private let connectivity: ConnectivityState
    private let storage: PackageStorage

    private(set) var record: PackageRecord?
    private(set) var content: ViewerContent?
    private(set) var markers: [Marker] = []
    private(set) var selectedMarkerID: String?
    let viewport = ViewportState()
    /// Guards the handshake against re-entry while one is already running.
    private var isOpening = false

    var displayState: PackageDisplayState {
        guard let record else { return .preparing(progress: nil) }
        return .make(
            state: record.state,
            reason: record.failureReason,
            retryCount: record.retryCount,
            isOffline: connectivity.isOffline,
            progress: record.downloadProgress,
            nextRetryAt: record.nextRetryAt
        )
    }

    init(
        projectID: String,
        packages: PackageRepository,
        markerRepository: MarkerRepository,
        preparation: any PreparationTriggering,
        connectivity: ConnectivityState,
        storage: PackageStorage
    ) {
        self.projectID = projectID
        self.packages = packages
        self.markerRepository = markerRepository
        self.preparation = preparation
        self.connectivity = connectivity
        self.storage = storage
    }

    // MARK: - Observation (each runs in its own `.task` on the screen)

    func observePackage() async {
        do {
            for try await snapshot in packages.observePackage(projectID: projectID) {
                record = snapshot
                if snapshot?.state == .ready {
                    // Self-healing open: a stable ready row emits exactly one snapshot, so a
                    // single lost race would otherwise spin forever. Retry until content exists,
                    // the row leaves ready, or the screen's task is cancelled.
                    while content == nil, record?.state == .ready, !Task.isCancelled {
                        await openForViewing()
                        if content == nil {
                            Log.viewer
                                .warning("Viewer open yielded no content for \(projectID, privacy: .public); retrying")
                            do {
                                try await Task.sleep(for: .seconds(1))
                            } catch {
                                return // screen went away — cancellation must not be swallowed
                            }
                        }
                    }
                } else {
                    content = nil // demoted / re-preparing: never render stale paths
                }
            }
        } catch {
            Log.viewer.error("Package observation failed: \(String(describing: error), privacy: .public)")
        }
    }

    func observeMarkers() async {
        do {
            for try await snapshot in markerRepository.observeMarkers(projectID: projectID) {
                markers = snapshot
                if let selected = selectedMarkerID, !snapshot.contains(where: { $0.id == selected }) {
                    selectedMarkerID = nil
                }
            }
        } catch {
            Log.viewer.error("Marker observation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The awaited viewer-entry handshake: verify-or-repair settles, then (and only then) the
    /// validated `ReadyPackage` becomes renderer content. A nil result means the package was
    /// demoted — the row observation will drive the state UI and re-trigger when ready again.
    private func openForViewing() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        Log.viewer.notice("Viewer entry: awaiting verify-or-repair for \(projectID, privacy: .public)")
        do {
            let package = try await preparation.packageForViewing(projectID: projectID)
            Log.viewer.notice("""
            Viewer entry settled for \(projectID, privacy: .public): \
            \(package == nil ? "no package (demoted or not ready)" : "validated package", privacy: .public)
            """)
            guard let package, let tilesURL = storage.absoluteURL(for: package.tilesRelDir) else { return }
            let descriptor = try DZIDescriptor(
                width: package.width,
                height: package.height,
                tileSize: package.tileSize,
                overlap: package.overlap,
                format: package.format
            )
            let pyramid = try TilePyramid(descriptor: descriptor, maxFolderLevel: package.maxFolderLevel)
            content = ViewerContent(
                pyramid: pyramid,
                provider: TileProvider(tilesDirectoryURL: tilesURL, pyramid: pyramid)
            )
        } catch {
            Log.viewer.error("Opening package failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Markers

    func handleTap(imagePoint: CGPoint) {
        guard let content else { return }
        let action = MarkerTapResolver.resolve(
            tapImagePoint: imagePoint,
            markers: markers,
            selectedID: selectedMarkerID,
            zoomScale: viewport.zoomScale,
            imageSize: content.imageSize
        )
        switch action {
        case let .place(normalizedX, normalizedY):
            Task { [markerRepository, projectID] in
                do {
                    try await markerRepository.insert(
                        projectID: projectID, normalizedX: normalizedX, normalizedY: normalizedY
                    )
                } catch {
                    Log.viewer.error("Placing marker failed: \(String(describing: error), privacy: .public)")
                }
            }
        case let .select(id):
            selectedMarkerID = id
        case .deselect:
            selectedMarkerID = nil
        case .none:
            break
        }
    }

    func deleteSelectedMarker() {
        guard let id = selectedMarkerID else { return }
        selectedMarkerID = nil
        Task { [markerRepository] in
            do {
                try await markerRepository.delete(id: id)
            } catch {
                Log.viewer.error("Deleting marker failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func retryNow() {
        Task { [preparation, projectID] in
            await preparation.retryNow(projectID: projectID)
        }
    }
}
