import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct ComicInfo: Sendable, Equatable {
    /// ComicInfo element names, including identity information in Notes and fractional Number.
    public var fields: [String: String]
    public var pages: [[String: String]]
    public init(fields: [String: String] = [:], pages: [[String: String]] = []) { self.fields = fields; self.pages = pages }
    public subscript(_ field: String) -> String? {
        get { fields[field] }
        set { fields[field] = newValue }
    }
}

public enum ComicInfoError: Error, Equatable { case invalidXML, tooLarge, invalidName(String) }

public enum ComicInfoCodec {
    public static let maximumBytes = 4 * 1_024 * 1_024
    public static func decode(_ data: Data) throws -> ComicInfo {
        guard data.count <= maximumBytes else { throw ComicInfoError.tooLarge }
        // ComicInfo needs no DTD. Reject declarations rather than allowing entity expansion.
        let utf16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let xml = String(data: data, encoding: .utf8) ?? (utf16BOM ? String(data: data, encoding: .utf16) : nil)
        guard let xml, !xml.contains("\0"), !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw ComicInfoError.invalidXML }
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.rootSeen, delegate.stack.isEmpty else { throw ComicInfoError.invalidXML }
        return delegate.result
    }
    public static func encode(_ info: ComicInfo) throws -> Data {
        func valid(_ name: String) throws {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { throw ComicInfoError.invalidName(name) }
        }
        func escape(_ value: String) throws -> String {
            guard value.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) }) else { throw ComicInfoError.invalidXML }
            return value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n"
        for name in info.fields.keys.sorted() {
            try valid(name)
            guard name != "Pages", name != "ComicInfo" else { throw ComicInfoError.invalidName(name) }
            xml += "  <\(name)>\(try escape(info.fields[name]!))</\(name)>\n"
        }
        if !info.pages.isEmpty {
            xml += "  <Pages>\n"
            for page in info.pages {
                xml += "    <Page"
                for name in page.keys.sorted() { try valid(name); xml += " \(name)=\"\(try escape(page[name]!))\"" }
                xml += "/>\n"
            }
            xml += "  </Pages>\n"
        }
        xml += "</ComicInfo>\n"
        let data = Data(xml.utf8)
        guard data.count <= maximumBytes else { throw ComicInfoError.tooLarge }
        return data
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var stack: [String] = []
        var result = ComicInfo()
        var text = ""
        var valid = true
        var rootSeen = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if stack.isEmpty {
                guard name == "ComicInfo", !rootSeen else { valid = false; parser.abortParsing(); return }
                rootSeen = true
            } else if stack.count == 1 { text = "" }
            else if stack == ["ComicInfo", "Pages"], name == "Page" { result.pages.append(attributes) }
            else { valid = false; parser.abortParsing(); return }
            stack.append(name)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if stack.count == 2 { text += string } }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let string = String(data: data, encoding: .utf8) else { valid = false; parser.abortParsing(); return }
            if stack.count == 2 { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count == 2, name != "Pages" {
                guard result.fields[name] == nil else { valid = false; parser.abortParsing(); return }
                result.fields[name] = text
            }
            _ = stack.popLast()
        }
    }
}

