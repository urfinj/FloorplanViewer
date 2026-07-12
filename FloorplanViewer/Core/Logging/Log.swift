import OSLog

/// Central logging facade. Categories map to the app's subsystems.
nonisolated enum Log {
    /// App lifecycle, launch, recovery.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Persistence: database, repositories, file storage.
    static let data = Logger(subsystem: subsystem, category: "data")
    /// Package preparation: download, extraction, validation, retry.
    static let prep = Logger(subsystem: subsystem, category: "prep")
    /// Tiled viewer and rendering.
    static let viewer = Logger(subsystem: subsystem, category: "viewer")

    private static let subsystem = "com.iphoner.floorplanviewer"
}
