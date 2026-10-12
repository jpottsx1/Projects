import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// An XML document read into memory, for the small, flat files Stash takes
/// in: web feeds and Evernote exports. Names are kept as written, prefix
/// and all (`content:encoded`), and compared ignoring case.
public final class XMLNode {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLNode] = []
    /// The text directly inside, CDATA included.
    public private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public static func parse(_ data: Data) -> XMLNode? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        // A feed with a stray error near the end still gives what came before.
        _ = parser.parse()
        return reader.root
    }

    /// The first child called `name`.
    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func children(_ name: String) -> [XMLNode] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The trimmed text of the first child called `name`, if it has any.
    public func string(_ name: String) -> String? {
        guard let text = child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
