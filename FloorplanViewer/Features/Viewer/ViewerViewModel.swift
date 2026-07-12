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
    /// Keeps verify-or-repair retries independent from the package observation stream. The
    /// pipeline can demote a broken `ready` row while the handshake is suspended; observation
    /// must remain free to consume that state change and replace the spinner with the real state.
    private var openingTask: Task<Void, Never>?
    private var openingGeneration = 0

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
        defer {
            cancelOpening()
        }
        do {
            for try await snapshot in packages.observePackage(projectID: projectID) {
                record = snapshot
                if snapshot?.state == .ready {
                    startOpeningIfNeeded()
                } else {
                    cancelOpening()
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
    private func startOpeningIfNeeded() {
        guard content == nil, openingTask == nil else { return }
        openingGeneration &+= 1
        let generation = openingGeneration
        openingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A cancelled older handshake must not clear the handle of a newer one.
                if openingGeneration == generation {
                    openingTask = nil
                }
            }
            // A stable ready row emits only once, so retry transient nil/error results. This task
            // does not own observation: if the pipeline demotes the row, the observer cancels us.
            while content == nil, record?.state == .ready, !Task.isCancelled {
                await openForViewing()
                guard content == nil, record?.state == .ready, !Task.isCancelled else { return }
                Log.viewer.warning(
                    "Viewer open yielded no content for \(self.projectID, privacy: .public); retrying"
                )
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func cancelOpening() {
        openingGeneration &+= 1
        openingTask?.cancel()
        openingTask = nil
    }

    private func openForViewing() async {
        Log.viewer.notice("Viewer entry: awaiting verify-or-repair for \(self.projectID, privacy: .public)")
        do {
            let package = try await preparation.packageForViewing(projectID: projectID)
            Log.viewer.notice("""
            Viewer entry settled for \(self.projectID, privacy: .public): \
            \(package == nil ? "no package (demoted or not ready)" : "validated package", privacy: .public)
            """)
            guard !Task.isCancelled, record?.state == .ready,
                  let package, let tilesURL = storage.absoluteURL(for: package.tilesRelDir)
            else { return }
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
