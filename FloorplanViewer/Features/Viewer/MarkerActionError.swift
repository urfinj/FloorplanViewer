import Foundation

/// Recoverable persistence failures surfaced after a user places or deletes a marker.
enum MarkerActionError: Identifiable {
    case insertFailed
    case deleteFailed

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .insertFailed:
            "Couldn’t Save Marker"
        case .deleteFailed:
            "Couldn’t Delete Marker"
        }
    }

    var message: String {
        switch self {
        case .insertFailed:
            "The marker wasn’t saved. Please try placing it again."
        case .deleteFailed:
            "The marker is still on the floorplan. Please try again."
        }
    }
}
