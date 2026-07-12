/// Parsed Deep Zoom Image (`.dzi`) descriptor — the authoritative source of image dimensions and
/// tiling parameters for a package. Pure value type, validated at construction so an invalid
/// descriptor can never exist (all pyramid math in `TilePyramid` may assume these invariants).
///
/// `nonisolated` because the module default isolation is `@MainActor` and this type is pure: it is
/// consumed from `@concurrent` validation/decode contexts and must not require the main actor.
nonisolated struct DZIDescriptor: Sendable, Equatable {
    /// Image width in full-resolution pixels (`> 0`).
    let width: Int
    /// Image height in full-resolution pixels (`> 0`).
    let height: Int
    /// Square tile edge in pixels (`> 0`).
    let tileSize: Int
    /// Per-edge tile overlap in pixels (`0 <= overlap < tileSize`).
    let overlap: Int
    /// Tile image format, lowercased, in ``supportedFormats``.
    let format: String

    /// Tile formats we accept. vips exports `jpg`; `jpeg`/`png` accepted for canonical-DZI
    /// generality. Compared against the lowercased descriptor value.
    static let supportedFormats: Set<String> = ["jpg", "jpeg", "png"]

    /// Creates a validated descriptor.
    ///
    /// - Throws: ``DZIDescriptorError`` when any DZI invariant is violated. `format` is lowercased
    ///   before the membership check, so `"JPG"`/`"PNG"` are accepted and normalized.
    init(width: Int, height: Int, tileSize: Int, overlap: Int, format: String) throws {
        guard width > 0 else { throw DZIDescriptorError.nonPositiveDimension(name: "Width", value: width) }
        guard height > 0 else { throw DZIDescriptorError.nonPositiveDimension(name: "Height", value: height) }
        guard tileSize > 0 else { throw DZIDescriptorError.nonPositiveDimension(name: "TileSize", value: tileSize) }
        guard overlap >= 0, overlap < tileSize else {
            throw DZIDescriptorError.overlapOutOfRange(overlap: overlap, tileSize: tileSize)
        }
        let normalizedFormat = format.lowercased()
        guard Self.supportedFormats.contains(normalizedFormat) else {
            throw DZIDescriptorError.unsupportedFormat(format)
        }
        self.width = width
        self.height = height
        self.tileSize = tileSize
        self.overlap = overlap
        self.format = normalizedFormat
    }
}

/// Invariant violations rejected by ``DZIDescriptor/init(width:height:tileSize:overlap:format:)``.
/// `DZIDescriptorParser` maps these onto `DZIParseError.invalidValue` so callers see one error
/// domain per entry point.
nonisolated enum DZIDescriptorError: Error, Equatable {
    /// `Width`, `Height`, or `TileSize` was `<= 0`.
    case nonPositiveDimension(name: String, value: Int)
    /// `overlap` was negative or `>= tileSize`.
    case overlapOutOfRange(overlap: Int, tileSize: Int)
    /// `format` (original casing) was not in ``DZIDescriptor/supportedFormats``.
    case unsupportedFormat(String)
}
