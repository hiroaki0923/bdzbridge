import Foundation

/// A minimal XML tree, enough for the recorder's SOAP responses, its `description.xml` and DIDL-Lite fragments.
///
/// Namespaces are dropped and every node keeps only its local name, which is how the reference implementation
/// compares tags. Nothing here is thread-safe; parse on the thread that uses the result.
public final class XmlNode {
    public let name: String
    public let attributes: [String: String]
    /// Character data belonging to this element itself, not to its children.
    public fileprivate(set) var text: String = ""
    public fileprivate(set) var children: [XmlNode] = []

    fileprivate init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public func child(_ name: String) -> XmlNode? {
        children.first { $0.name == name }
    }

    /// Text of a direct child, with control characters removed the way the recorder's values need.
    /// Missing and empty elements both give `defaultValue`.
    public func childText(_ name: String, default defaultValue: String = "") -> String {
        guard let node = child(name) else { return defaultValue }
        let cleaned = node.strippedText
        return cleaned.isEmpty ? defaultValue : cleaned
    }

    /// Control characters removed, newlines kept.
    public var strippedText: String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" }))
    }

    /// The first element with this local name anywhere below (and including) this one, in document order.
    public func firstDescendant(_ name: String) -> XmlNode? {
        if self.name == name { return self }
        for child in children {
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Every element with this local name anywhere below (and including) this one, in document order.
    public func descendants(_ name: String) -> [XmlNode] {
        var out: [XmlNode] = []
        if self.name == name { out.append(self) }
        for child in children { out += child.descendants(name) }
        return out
    }

    /// Text of the first element with this local name anywhere below, or nil when there is none.
    public func firstDescendantText(_ name: String) -> String? {
        firstDescendant(name)?.text
    }

    public static func parse(_ xml: String) throws -> XmlNode {
        guard let data = xml.data(using: .utf8) else { throw XmlError.notUtf8 }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> XmlNode {
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw XmlError.malformed(parser.parserError?.localizedDescription ?? "could not be parsed")
        }
        return root
    }
}

public enum XmlError: Error, CustomStringConvertible {
    case notUtf8
    case malformed(String)

    public var description: String {
        switch self {
        case .notUtf8: "XML was not valid UTF-8"
        case .malformed(let why): "malformed XML: \(why)"
        }
    }
}

private func localName(_ qualified: String) -> String {
    qualified.split(separator: ":").last.map(String.init) ?? qualified
}

private final class Builder: NSObject, XMLParserDelegate {
    var root: XmlNode?
    private var stack: [XmlNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
            attributes[localName(key)] = value
        }
        let node = XmlNode(name: localName(elementName), attributes: attributes)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}
