import Testing
@testable import FloorplanViewer

struct DZIDescriptorTests {
    @Test func validDescriptorKeepsFields() throws {
        let descriptor = try DZIDescriptor(width: 3300, height: 2552, tileSize: 256, overlap: 0, format: "jpg")
        #expect(descriptor.width == 3300)
        #expect(descriptor.height == 2552)
        #expect(descriptor.tileSize == 256)
        #expect(descriptor.overlap == 0)
        #expect(descriptor.format == "jpg")
    }

    @Test(arguments: ["JPG", "Jpg", "PNG", "JPEG", "jpeg", "png"])
    func formatIsLowercasedAndAccepted(_ format: String) throws {
        let descriptor = try DZIDescriptor(width: 10, height: 10, tileSize: 8, overlap: 0, format: format)
        #expect(descriptor.format == format.lowercased())
    }

    @Test(arguments: ["gif", "bmp", "tiff", ""])
    func unsupportedFormatThrows(_ format: String) {
        #expect(throws: DZIDescriptorError.unsupportedFormat(format)) {
            try DZIDescriptor(width: 10, height: 10, tileSize: 8, overlap: 0, format: format)
        }
    }

    @Test(arguments: [(0, 10, 8), (10, 0, 8), (10, 10, 0), (-1, 10, 8), (10, -5, 8), (10, 10, -3)])
    func nonPositiveDimensionsThrow(_ dimensions: (Int, Int, Int)) {
        let (width, height, tileSize) = dimensions
        #expect(throws: DZIDescriptorError.self) {
            try DZIDescriptor(width: width, height: height, tileSize: tileSize, overlap: 0, format: "jpg")
        }
    }

    @Test(arguments: [-1, 256, 300])
    func overlapOutOfRangeThrows(_ overlap: Int) {
        #expect(throws: DZIDescriptorError.overlapOutOfRange(overlap: overlap, tileSize: 256)) {
            try DZIDescriptor(width: 100, height: 100, tileSize: 256, overlap: overlap, format: "jpg")
        }
    }

    @Test func overlapJustBelowTileSizeIsValid() throws {
        let descriptor = try DZIDescriptor(width: 100, height: 100, tileSize: 256, overlap: 255, format: "jpg")
        #expect(descriptor.overlap == 255)
    }

    @Test func zeroOverlapIsValid() throws {
        let descriptor = try DZIDescriptor(width: 100, height: 100, tileSize: 256, overlap: 0, format: "jpg")
        #expect(descriptor.overlap == 0)
    }
}
