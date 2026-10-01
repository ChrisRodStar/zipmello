import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Structured ComicInfo metadata model following the ComicRack schema specification.
public struct ComicInfo: Sendable, Equatable {
    /// Dictionary of ComicInfo element names and text values (e.g., "Series", "Title", "Number").
    public var fields: [String: String]

    /// Array of page attribute dictionaries (e.g., ["Image": "0", "Type": "FrontCover"]).
    public var pages: [[String: String]]

    public init(fields: [String: String] = [:], pages: [[String: String]] = []) {
        self.fields = fields
        self.pages = pages
    }

    /// Accesses or updates a ComicInfo field by element name.
    public subscript(_ field: String) -> String? {
        get { fields[field] }
        set { fields[field] = newValue }
    }
}

/// Errors occurring during ComicInfo XML encoding or decoding.
public enum ComicInfoError: Error, Equatable {
    case invalidXML
    case tooLarge
    case invalidName(String)
}

/// Secure encoder and decoder for ComicRack `ComicInfo.xml` metadata.
///
/// Implements strict protections against XML External Entity (XXE) injection, entity expansion bombs,
/// and invalid XML character injection.
public enum ComicInfoCodec {
    /// Maximum allowed payload size for ComicInfo XML documents (4 MB).
    public static let maximumBytes = 4 * 1024 * 1024

    /// Decodes a `ComicInfo` structure from raw XML bytes.
    ///
    /// - Parameter data: UTF-8 or UTF-16 encoded XML data.
    /// - Returns: Parsed `ComicInfo` structure.
    /// - Throws: `ComicInfoError` if the XML is malformed, contains DTD/entities, or exceeds size limits.
    public static func decode(_ data: Data) throws -> ComicInfo {
        guard data.count <= maximumBytes else {
            throw ComicInfoError.tooLarge
        }

        // Detect BOM for UTF-16 LE/BE or default to UTF-8.
        let utf16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let xmlString = String(data: data, encoding: .utf8) ?? (utf16BOM ? String(data: data, encoding: .utf16) : nil)

        // XXE and Entity Expansion Prevention: ComicInfo documents require no DTD declarations.
        // Rejecting DOCTYPE and ENTITY markers upfront guarantees external entities cannot be resolved.
        guard let xml = xmlString,
              !xml.contains("\0"),
              !xml.contains("<!DOCTYPE"),
              !xml.contains("<!ENTITY") else {
            throw ComicInfoError.invalidXML
        }

        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate

        guard parser.parse(), delegate.valid, delegate.rootSeen, delegate.stack.isEmpty else {
            throw ComicInfoError.invalidXML
        }

        return delegate.result
    }

    /// Serializes a `ComicInfo` instance into canonical UTF-8 XML.
    ///
    /// - Parameter info: The `ComicInfo` model to serialize.
    /// - Returns: Validated UTF-8 XML byte representation.
    /// - Throws: `ComicInfoError` if any tag name or scalar character is invalid.
    public static func encode(_ info: ComicInfo) throws -> Data {
        func validateTagName(_ name: String) throws {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
                throw ComicInfoError.invalidName(name)
            }
        }

        func escapeValue(_ value: String) throws -> String {
            let isValid = value.unicodeScalars.allSatisfy { scalar in
                scalar.value == 9
                    || scalar.value == 10
                    || scalar.value == 13
                    || (scalar.value >= 32 && scalar.value != 0xFFFE && scalar.value != 0xFFFF)
            }
            guard isValid else {
                throw ComicInfoError.invalidXML
            }

            return value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n"

        for name in info.fields.keys.sorted() {
            try validateTagName(name)
            guard name != "Pages", name != "ComicInfo" else {
                throw ComicInfoError.invalidName(name)
            }
            let escapedText = try escapeValue(info.fields[name]!)
            xml += "  <\(name)>\(escapedText)</\(name)>\n"
        }

        if !info.pages.isEmpty {
            xml += "  <Pages>\n"
            for page in info.pages {
                xml += "    <Page"
                for name in page.keys.sorted() {
                    try validateTagName(name)
                    let escapedAttr = try escapeValue(page[name]!)
                    xml += " \(name)=\"\(escapedAttr)\""
                }
                xml += "/>\n"
            }
            xml += "  </Pages>\n"
        }

        xml += "</ComicInfo>\n"

        let data = Data(xml.utf8)
        guard data.count <= maximumBytes else {
            throw ComicInfoError.tooLarge
        }
        return data
    }

    // MARK: - Private XML Parser Delegate

    private final class Parser: NSObject, XMLParserDelegate {
        var stack: [String] = []
        var result = ComicInfo()
        var text = ""
        var valid = true
        var rootSeen = false

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            if stack.isEmpty {
                guard name == "ComicInfo", !rootSeen else {
                    valid = false
                    parser.abortParsing()
                    return
                }
                rootSeen = true
            } else if stack.count == 1 {
                text = ""
            } else if stack == ["ComicInfo", "Pages"], name == "Page" {
                result.pages.append(attributes)
            } else {
                valid = false
                parser.abortParsing()
                return
            }
            stack.append(name)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if stack.count == 2 {
                text += string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let string = String(data: data, encoding: .utf8) else {
                valid = false
                parser.abortParsing()
                return
            }
            if stack.count == 2 {
                text += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement name: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if stack.count == 2, name != "Pages" {
                guard result.fields[name] == nil else {
                    valid = false
                    parser.abortParsing()
                    return
                }
                result.fields[name] = text
            }
            _ = stack.popLast()
        }
    }
}
