import Foundation

/// Parses a DZI XML descriptor into a validated ``DZIDescriptor`` using Foundation's `XMLParser`.
///
/// The `XMLParser` and its delegate are non-`Sendable`, so they are created, driven, and discarded
/// entirely inside ``parse(_:)`` — nothing escapes, and the (`nonisolated`) function is safe to
/// call from `@concurrent` validation contexts.
///
/// Parsing is namespace-agnostic (the samples use the `deepzoom/2008` default namespace): element
/// **local names** (`Image`, `Size`) and attribute names are matched case-insensitively, and
/// attribute values are whitespace-trimmed (the samples carry stray whitespace).
nonisolated enum DZIDescriptorParser {
    /// Parses `data` as a DZI descriptor.
    ///
    /// - Throws: ``DZIParseError`` — `.notXML` when the bytes are not parseable XML or contain no
    ///   `Image` element; `.missingAttribute` / `.invalidValue` for absent or malformed fields.
    static func parse(_ data: Data) throws -> DZIDescriptor {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true // report local names, so any namespace/prefix works.
        let collector = ElementCollector()
        parser.delegate = collector

        guard parser.parse(), let imageAttributes = collector.imageAttributes else {
            throw DZIParseError.notXML
        }
        // A missing `Size` element surfaces as a missing `Width`/`Height` attribute below.
        let sizeAttributes = collector.sizeAttributes ?? [:]

        let format = try requiredValue(in: imageAttributes, named: "Format")
        let overlapText = try requiredValue(in: imageAttributes, named: "Overlap")
        let tileSizeText = try requiredValue(in: imageAttributes, named: "TileSize")
        let widthText = try requiredValue(in: sizeAttributes, named: "Width")
        let heightText = try requiredValue(in: sizeAttributes, named: "Height")

        let width = try intValue(widthText, named: "Width")
        let height = try intValue(heightText, named: "Height")
        let tileSize = try intValue(tileSizeText, named: "TileSize")
        let overlap = try intValue(overlapText, named: "Overlap")

        do {
            return try DZIDescriptor(
                width: width,
                height: height,
                tileSize: tileSize,
                overlap: overlap,
                format: format
            )
        } catch let error as DZIDescriptorError {
            throw parseError(from: error)
        }
    }

    /// Case-insensitive attribute lookup returning the whitespace-trimmed value.
    private static func requiredValue(in attributes: [String: String], named name: String) throws -> String {
        for (key, value) in attributes where key.caseInsensitiveCompare(name) == .orderedSame {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DZIParseError.missingAttribute(name: name)
    }

    private static func intValue(_ text: String, named name: String) throws -> Int {
        guard let value = Int(text) else { throw DZIParseError.invalidValue(name: name, value: text) }
        return value
    }

    /// Re-expresses a descriptor invariant violation as the equivalent parse error, so callers of
    /// ``parse(_:)`` observe a single error domain.
    private static func parseError(from error: DZIDescriptorError) -> DZIParseError {
        switch error {
        case let .nonPositiveDimension(name, value):
            .invalidValue(name: name, value: String(value))
        case let .overlapOutOfRange(overlap, _):
            .invalidValue(name: "Overlap", value: String(overlap))
        case let .unsupportedFormat(format):
            .invalidValue(name: "Format", value: format)
        }
    }
}

/// Errors surfaced by ``DZIDescriptorParser/parse(_:)``.
nonisolated enum DZIParseError: Error, Equatable {
    /// Bytes were not parseable XML, or contained no `Image` element.
    case notXML
    /// A required attribute (`Format`/`Overlap`/`TileSize`/`Width`/`Height`) was absent.
    case missingAttribute(name: String)
    /// An attribute was present but its value was non-numeric or violated a DZI invariant.
    case invalidValue(name: String, value: String)
}

/// `XMLParser` delegate that records the first `Image` and `Size` element attributes. File-private
/// and `nonisolated`: instances never leave ``DZIDescriptorParser/parse(_:)`` and the delegate
/// callbacks run synchronously on the parsing thread (never the main actor).
private final nonisolated class ElementCollector: NSObject, XMLParserDelegate {
    private(set) var imageAttributes: [String: String]?
    private(set) var sizeAttributes: [String: String]?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName.lowercased() {
        case "image" where imageAttributes == nil:
            imageAttributes = attributeDict
        case "size" where sizeAttributes == nil:
            sizeAttributes = attributeDict
        default:
            break
        }
    }
}
