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
    /// What the overlay renders: the last observed snapshot merged with any optimistic pins.
    private(set) var markers: [Marker] = []
    /// Last confirmed snapshot from the marker observation.
    private var persistedMarkers: [Marker] = []
    /// Pins shown immediately on placement, before the write round-trips back through observation —
    /// dropped once a snapshot proves them persisted. Kills the tap-to-appear latency.
    private var pendingInserts: [Marker] = []
    private(set) var selectedMarkerID: String?
    /// Set only when a user-triggered marker write fails; the screen clears it on alert dismissal.
    var markerActionError: MarkerActionError?
    let viewport = ViewportState()
    /// Command bridge for the discrete zoom buttons; installed by the scroll-view representable.
    let viewportController = ViewportController()
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

    // MARK: - Observation (structured children of RootView's selected-project task)

    func observePackage() async {
        defer {
            cancelOpening()
        }
        while !Task.isCancelled {
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
                if Task.isCancelled {
                    return
                }
                Log.viewer.warning("Package observation ended for \(self.projectID, privacy: .public); reconnecting")
            } catch {
                if error is CancellationError || Task.isCancelled {
                    return
                }
                Log.viewer.error("Package observation failed: \(String(describing: error), privacy: .public)")
            }
            guard await waitBeforeObservationReconnect() else { return }
        }
    }

    func observeMarkers() async {
        while !Task.isCancelled {
            do {
                for try await snapshot in markerRepository.observeMarkers(projectID: projectID) {
                    persistedMarkers = snapshot
                    // Any optimistic pin the snapshot now contains is confirmed — stop tracking it.
                    let persistedIDs = Set(snapshot.map(\.id))
                    pendingInserts.removeAll { persistedIDs.contains($0.id) }
                    recomputeMarkers()
                    if let selected = selectedMarkerID, !markers.contains(where: { $0.id == selected }) {
                        selectedMarkerID = nil
                    }
                }
                if Task.isCancelled {
                    return
                }
                Log.viewer.warning("Marker observation ended for \(self.projectID, privacy: .public); reconnecting")
            } catch {
                if error is CancellationError || Task.isCancelled {
                    return
                }
                Log.viewer.error("Marker observation failed: \(String(describing: error), privacy: .public)")
            }
            guard await waitBeforeObservationReconnect() else { return }
        }
    }

    private func waitBeforeObservationReconnect() async -> Bool {
        do {
            try await Task.sleep(for: .seconds(1))
            return !Task.isCancelled
        } catch {
            return false
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
            // Law: classify cancellation first — a torn-down screen is not an error.
            if error is CancellationError || Task.isCancelled {
                return
            }
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
            placeMarker(normalizedX: normalizedX, normalizedY: normalizedY)
        case let .select(id):
            selectedMarkerID = id
        case .deselect:
            selectedMarkerID = nil
        case .none:
            break
        }
    }

    /// VoiceOver activation path (the overlay's pins are not touch-hittable by design).
    func toggleSelection(of markerID: String) {
        selectedMarkerID = selectedMarkerID == markerID ? nil : markerID
    }

    /// The selected marker's live row, feeding the inspector sheet via `sheet(item:)`. Turns nil
    /// the moment the marker is deleted or deselected, which dismisses the sheet.
    var selectedMarker: Marker? {
        guard let selectedMarkerID else { return nil }
        return markers.first { $0.id == selectedMarkerID }
    }

    /// 1-based position in creation order — the number VoiceOver announces and the sheet titles.
    func markerNumber(for marker: Marker) -> Int {
        (markers.firstIndex(of: marker) ?? 0) + 1
    }

    func deselectMarker() {
        selectedMarkerID = nil
    }

    /// Drops a pin at whatever plan point currently sits under the viewport center — the
    /// no-aiming complement to tap-to-drop (and the VoiceOver-friendly placement path).
    func placeMarkerAtViewportCenter() {
        guard let content else { return }
        let center = CGPoint(x: viewport.boundsSize.width / 2, y: viewport.boundsSize.height / 2)
        guard let normalized = ViewportMath.normalizedPoint(
            screenPoint: center,
            zoomScale: viewport.zoomScale,
            contentOffset: viewport.contentOffset,
            imageSize: content.imageSize
        ) else { return }
        placeMarker(normalizedX: normalized.x, normalizedY: normalized.y)
    }

    private func placeMarker(normalizedX: Double, normalizedY: Double) {
        let marker = markerRepository.makeMarker(
            projectID: projectID, normalizedX: normalizedX, normalizedY: normalizedY
        )
        // Optimistic: the pin is on screen this frame; the write + observation confirm it a beat
        // later and simply replace the optimistic copy with the identical persisted row.
        pendingInserts.append(marker)
        recomputeMarkers()
        Task { [weak self, markerRepository] in
            do {
                try await markerRepository.insert(marker)
            } catch {
                Log.viewer.error("Placing marker failed: \(String(describing: error), privacy: .public)")
                // Persisting failed — take the optimistic pin back down.
                self?.pendingInserts.removeAll { $0.id == marker.id }
                self?.recomputeMarkers()
                self?.markerActionError = .insertFailed
            }
        }
    }

    /// Merges the confirmed snapshot with still-pending optimistic pins, keyed by id (pending never
    /// duplicates a persisted row) and ordered by creation time — the overlay's stable pin numbers.
    private func recomputeMarkers() {
        guard !pendingInserts.isEmpty else {
            markers = persistedMarkers
            return
        }
        var byID: [String: Marker] = [:]
        byID.reserveCapacity(persistedMarkers.count + pendingInserts.count)
        for marker in persistedMarkers {
            byID[marker.id] = marker
        }
        for marker in pendingInserts {
            byID[marker.id] = marker
        }
        markers = byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Zoom

    func zoomIn() {
        viewportController.zoomIn()
    }

    func zoomOut() {
        viewportController.zoomOut()
    }

    /// Animate straight back to the fitted (whole-plan) scale — the one-tap overview reset.
    func resetZoom() {
        viewportController.fit()
    }

    func deleteSelectedMarker() {
        guard let id = selectedMarkerID else { return }
        selectedMarkerID = nil
        Task { [markerRepository] in
            do {
                try await markerRepository.delete(id: id)
            } catch {
                Log.viewer.error("Deleting marker failed: \(String(describing: error), privacy: .public)")
                markerActionError = .deleteFailed
            }
        }
    }

    func retryNow() {
        Task { [preparation, projectID] in
            await preparation.retryNow(projectID: projectID)
        }
    }
}
