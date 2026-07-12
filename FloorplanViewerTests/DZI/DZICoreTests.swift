import Foundation
import Testing
@testable import FloorplanViewer

/// Compact DZI-core coverage: the real sample-1 descriptor, the rebased-pyramid ground truth,
/// LOD mapping, and the locator over the two real-world layouts. (Deeper edge matrices are a
/// documented later-work item — these pin the formulas the viewer and validator stand on.)
struct DZICoreTests {
    /// Verbatim from the real sample-1 archive, whitespace quirks intact.
    private static let sampleDescriptorXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Image xmlns="http://schemas.microsoft.com/deepzoom/2008"
      Format="jpg"
      Overlap="0"
      TileSize="256"
      >
      <Size
        Height="2552"
        Width="3300"
      />
    </Image>
    """

    @Test func parsesRealSampleDescriptor() throws {
        let descriptor = try DZIDescriptorParser.parse(Data(Self.sampleDescriptorXML.utf8))
        #expect(try descriptor == DZIDescriptor(width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg"))
    }

    @Test func parserRejectsMissingAndInvalid() {
        #expect(throws: DZIParseError.notXML) {
            try DZIDescriptorParser.parse(Data("not xml".utf8))
        }
        #expect(throws: DZIParseError.missingAttribute(name: "TileSize")) {
            try DZIDescriptorParser.parse(Data(
                "<Image Format=\"jpg\" Overlap=\"0\"><Size Width=\"10\" Height=\"10\"/></Image>".utf8
            ))
        }
        #expect(throws: DZIParseError.invalidValue(name: "Width", value: "wide")) {
            try DZIDescriptorParser.parse(Data(
                "<Image Format=\"jpg\" Overlap=\"0\" TileSize=\"256\"><Size Width=\"wide\" Height=\"10\"/></Image>".utf8
            ))
        }
    }

    // MARK: - Pyramid ground truth (real sample-1 numbers)

    private var samplePyramid: TilePyramid {
        get throws {
            try TilePyramid(
                descriptor: DZIDescriptor(width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg"),
                maxFolderLevel: 4
            )
        }
    }

    @Test(arguments: [
        (level: 0, width: 207, height: 160, cols: 1, rows: 1),
        (level: 1, width: 413, height: 319, cols: 2, rows: 2),
        (level: 2, width: 825, height: 638, cols: 4, rows: 3),
        (level: 3, width: 1650, height: 1276, cols: 7, rows: 5),
        (level: 4, width: 3300, height: 2552, cols: 13, rows: 10)
    ])
    func rebasedPyramidMatchesGroundTruth(
        entry: (level: Int, width: Int, height: Int, cols: Int, rows: Int)
    ) throws {
        let pyramid = try samplePyramid
        #expect(pyramid.size(atLevel: entry.level) == CGSize(width: entry.width, height: entry.height))
        let grid = pyramid.grid(atLevel: entry.level)
        #expect(grid.cols == entry.cols)
        #expect(grid.rows == entry.rows)
    }

    @Test func edgeTileFrameClipsToImageBounds() throws {
        let frame = try samplePyramid.tileFrameInLevelSpace(level: 4, col: 12, row: 9)
        #expect(frame == CGRect(x: 3072, y: 2304, width: 228, height: 248))
    }

    @Test(arguments: [
        (scale: 1.0, level: 4), (scale: 0.5, level: 3), (scale: 0.25, level: 2),
        (scale: 0.125, level: 1), (scale: 0.0625, level: 0),
        (scale: 0.03, level: 0), (scale: 2.0, level: 4), (scale: 4.0, level: 4)
    ])
    func lodScaleMapsToFolderLevel(entry: (scale: Double, level: Int)) throws {
        #expect(try samplePyramid.folderLevel(forLODScale: entry.scale) == entry.level)
    }

    @Test func tileIndicesClampToGrid() throws {
        let pyramid = try samplePyramid
        // Full image at max level → the whole 13×10 grid.
        let all = pyramid.tileIndices(intersecting: CGRect(x: 0, y: 0, width: 3300, height: 2552), atLevel: 4)
        #expect(all.cols == 0 ..< 13)
        #expect(all.rows == 0 ..< 10)
        // A one-tile window in the middle.
        let mid = pyramid.tileIndices(intersecting: CGRect(x: 300, y: 300, width: 10, height: 10), atLevel: 4)
        #expect(mid.cols == 1 ..< 2)
        #expect(mid.rows == 1 ..< 2)
        // Disjoint rect → empty.
        let out = pyramid.tileIndices(intersecting: CGRect(x: 9000, y: 9000, width: 10, height: 10), atLevel: 4)
        #expect(out.cols.isEmpty)
        #expect(out.rows.isEmpty)
    }

    // MARK: - Locator over the two real-world layouts

    @Test func locatorFindsSampleAndCanonicalLayouts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dzi-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        // Real archive shape: wrapper dir + `tileset/floorplan.dzi` + sibling `tiles/{0..4}`.
        let tileset = root.appending(path: "sample/tileset")
        for level in 0 ... 4 {
            try FileManager.default.createDirectory(
                at: tileset.appending(path: "tiles/\(level)"), withIntermediateDirectories: true
            )
        }
        try Data(Self.sampleDescriptorXML.utf8).write(to: tileset.appending(path: "floorplan.dzi"))

        let layout = try DZIPackageLocator.locate(in: root)
        #expect(layout.descriptorURL.lastPathComponent == "floorplan.dzi")
        #expect(layout.tilesDirectoryURL.lastPathComponent == "tiles")
        #expect(try TilePyramid.discoverMaxFolderLevel(tilesDirectoryURL: layout.tilesDirectoryURL) == 4)

        // Canonical shape: `plan.dzi` + `plan_files/` wins over any other sibling.
        let canonical = root.appending(path: "canonical")
        try FileManager.default.createDirectory(
            at: canonical.appending(path: "plan_files/0"), withIntermediateDirectories: true
        )
        try Data(Self.sampleDescriptorXML.utf8).write(to: canonical.appending(path: "plan.dzi"))
        let canonicalLayout = try DZIPackageLocator.locate(in: canonical)
        #expect(canonicalLayout.tilesDirectoryURL.lastPathComponent == "plan_files")

        // Empty tree → descriptorNotFound.
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: DZILocatorError.descriptorNotFound) {
            try DZIPackageLocator.locate(in: empty)
        }
    }
}
