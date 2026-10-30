import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum ESCLDocumentFormat: String, Equatable, Sendable, CaseIterable {
    case jpeg = "image/jpeg"
    case pdf = "application/pdf"
}

public enum ESCLScanSettingsError: Error, Equatable, Sendable, LocalizedError {
    case malformedXML(String)
    case unsupportedInputSource(String)
    case unsupportedDocumentFormat(String)

    public var errorDescription: String? {
        switch self {
        case .malformedXML(let detail):
            "ScanSettings is not valid XML: \(detail)"
        case .unsupportedInputSource(let source):
            "Input source \(source) is not supported; this scanner only has a document feeder."
        case .unsupportedDocumentFormat(let format):
            "Document format \(format) is not supported."
        }
    }
}

/// The subset of an eSCL `ScanSettings` request that changes what the iX500 does.
///
/// Colour mode, resolution, intent, and scan regions are accepted but not applied: Wi-Fi
/// acquisition always returns 300 dpi colour JPEG sides at the size the scanner detected.
public struct ESCLScanSettings: Equatable, Sendable {
    public var duplex: Bool
    public var documentFormat: ESCLDocumentFormat
    public var colorMode: String?
    public var resolution: Int?
    public var intent: String?

    public init(
        duplex: Bool = false,
        documentFormat: ESCLDocumentFormat = .jpeg,
        colorMode: String? = nil,
        resolution: Int? = nil,
        intent: String? = nil
    ) {
        self.duplex = duplex
        self.documentFormat = documentFormat
        self.colorMode = colorMode
        self.resolution = resolution
        self.intent = intent
    }

    public init(xml: Data) throws {
        let collector = ESCLElementCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse() else {
            throw ESCLScanSettingsError.malformedXML(
                parser.parserError?.localizedDescription ?? "unknown parser error"
            )
        }
        // swift-corelibs-foundation's parser can report success for a truncated document.
        guard collector.depth == 0 else {
            throw ESCLScanSettingsError.malformedXML("document ended before its root element closed")
        }
        guard collector.rootName == "ScanSettings" else {
            throw ESCLScanSettingsError.malformedXML("root element is not ScanSettings")
        }
        let values = collector.values

        if let source = values["InputSource"], source.lowercased() != "feeder" {
            throw ESCLScanSettingsError.unsupportedInputSource(source)
        }

        // Clients send DocumentFormatExt (eSCL 2.1+) and/or the older pwg:DocumentFormat.
        // Treat a missing format or the generic octet-stream as the scanner's native JPEG.
        let requestedFormat = values["DocumentFormatExt"] ?? values["DocumentFormat"]
        let format: ESCLDocumentFormat
        switch requestedFormat?.lowercased() {
        case nil, "", "application/octet-stream", "image/jpeg", "image/jpg":
            format = .jpeg
        case "application/pdf":
            format = .pdf
        case let other?:
            throw ESCLScanSettingsError.unsupportedDocumentFormat(other)
        }

        self.init(
            duplex: values["Duplex"].map(Self.isTrue) ?? false,
            documentFormat: format,
            colorMode: values["ColorMode"],
            resolution: values["XResolution"].flatMap { Int($0) },
            intent: values["Intent"]
        )
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "1"].contains(value.lowercased())
    }
}

/// Collects the text of leaf elements by local name, ignoring namespace prefixes. The first
/// occurrence wins, which keeps a nested `pwg:DocumentFormat` inside `ScanRegions` (not used by
/// real clients, but legal) from overriding the top-level value.
private final class ESCLElementCollector: NSObject, XMLParserDelegate {
    private(set) var rootName: String?
    private(set) var values: [String: String] = [:]
    private(set) var depth = 0
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootName == nil { rootName = Self.localName(elementName) }
        depth += 1
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Self.localName(elementName)
        if !value.isEmpty, values[name] == nil {
            values[name] = value
        }
        text = ""
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
