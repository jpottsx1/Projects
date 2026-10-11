import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What's needed to read an EPUB book: its chapters in reading order, its
/// table of contents, and its title. Paths are the book's own, inside the
/// ZIP file, so the reader can ask for them.
public struct EPUBBook: Equatable {
    public struct Chapter: Equatable {
        /// Inside the book, from its root: "OEBPS/text/chapter1.xhtml".
        public var path: String
        public var mediaType: String
    }

    public struct TOCEntry: Equatable {
        public var title: String
        /// A chapter path, perhaps with "#section" after it.
        public var target: String
        public var level: Int
    }

    public var title: String?
    public var author: String?
    public var chapters: [Chapter]
    public var toc: [TOCEntry]

    public enum Failure: Error, Equatable {
        case noPackage
        case unreadable(String)
    }

    /// Reads the book through `file`, which returns the file at a path inside it.
    public init(file: (String) throws -> Data) throws {
        let container = try Self.parse(try file("META-INF/container.xml"))
        guard let packagePath = container.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else {
            throw Failure.noPackage
        }
        let package = try Self.parse(try file(packagePath))
        let base = Self.directory(of: packagePath)

        var manifest: [String: (path: String, type: String, properties: String)] = [:]
        for element in package where element.name == "item" {
            guard let id = element.attributes["id"], let href = element.attributes["href"] else { continue }
            manifest[id] = (Self.resolve(href, from: base), element.attributes["media-type"] ?? "",
                            element.attributes["properties"] ?? "")
        }

        title = package.first { $0.name == "title" }.map(\.text).flatMap(Self.nonEmpty)
        author = package.first { $0.name == "creator" }.map(\.text).flatMap(Self.nonEmpty)
        chapters = package.filter { $0.name == "itemref" && $0.attributes["linear"] != "no" }
            .compactMap { $0.attributes["idref"].flatMap { manifest[$0] } }
            .map { Chapter(path: $0.path, mediaType: $0.type) }

        // EPUB 3 keeps its contents in a page marked "nav"; EPUB 2 in an NCX file.
        var toc: [TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let data = try? file(nav.path) {
            toc = Self.navTOC(data, base: Self.directory(of: nav.path))
        }
        if toc.isEmpty {
            let spineTOC = package.first { $0.name == "spine" }?.attributes["toc"]
            let ncx = spineTOC.flatMap { manifest[$0] }
                ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }
            if let ncx, let data = try? file(ncx.path) {
                toc = Self.ncxTOC(data, base: Self.directory(of: ncx.path))
            }
        }
        self.toc = toc
    }

    /// Which chapter a table-of-contents target is in.
    public func chapterIndex(for target: String) -> Int? {
        let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        return chapters.firstIndex { $0.path == path }
    }

    // MARK: - Tables of contents

    private static func navTOC(_ data: Data, base: String) -> [TOCEntry] {
        guard let elements = try? parse(data) else { return [] }
        // The <nav epub:type="toc">, not the page list or landmarks.
        guard let start = elements.firstIndex(where: {
            $0.name == "nav" && ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").contains("toc")
        }) ?? elements.firstIndex(where: { $0.name == "nav" }) else { return [] }
        let navDepth = elements[start].depth
        var entries: [TOCEntry] = []
        for element in elements[(start + 1)...] {
            if element.depth <= navDepth { break }
            guard element.name == "a", let href = element.attributes["href"],
                  let title = nonEmpty(element.text) else { continue }
            // Each nested list is two levels down: <ol><li>.
            entries.append(TOCEntry(title: title, target: resolve(href, from: base), level: element.listDepth - 1))
        }
        return entries
    }

    private static func ncxTOC(_ data: Data, base: String) -> [TOCEntry] {
        guard let elements = try? parse(data) else { return [] }
        var entries: [TOCEntry] = []
        var pendingTitle: String?
        var navPointDepths: [Int] = []
        for element in elements {
            switch element.name {
            case "navPoint":
                navPointDepths.removeAll { $0 >= element.depth }
                navPointDepths.append(element.depth)
                pendingTitle = nil
            case "text":
                if pendingTitle == nil { pendingTitle = nonEmpty(element.text) }
            case "content":
                if let src = element.attributes["src"], let title = pendingTitle {
                    entries.append(TOCEntry(title: title, target: resolve(src, from: base),
                                            level: max(0, navPointDepths.count - 1)))
                    pendingTitle = nil
                }
            default:
                break
            }
        }
        return entries
    }

    // MARK: - Paths

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// A link inside the book, made relative to the root: "../images/a.png"
    /// from "OEBPS/text/" is "OEBPS/images/a.png". Percent escapes are undone.
    public static func resolve(_ href: String, from base: String) -> String {
        let (path, fragment): (Substring, Substring?) = {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }()
        let decoded = String(path).removingPercentEncoding ?? String(path)
        var parts: [Substring] = decoded.hasPrefix("/") ? [] : base.split(separator: "/")
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        if let fragment, !fragment.isEmpty { return joined + "#" + fragment }
        return joined
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - XML

    /// Every element in document order, flattened: its name without a
    /// namespace prefix, attributes, the text inside it (including inside
    /// its children), and how deep it is.
    struct Element {
        var name: String
        var attributes: [String: String]
        var text = ""
        var depth: Int
        /// How many <ol>/<ul> and <li> elements it's inside.
        var listDepth: Int
    }

    static func parse(_ data: Data) throws -> [Element] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        // Books often name HTML entities XML doesn't know (&nbsp;); the
        // parser stops there, but what came before is still usable.
        if !parser.parse(), collector.elements.isEmpty {
            throw Failure.unreadable(parser.parserError?.localizedDescription ?? "XML")
        }
        return collector.elements
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        private var open: [Int] = []
        private var listDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "li" || name == "ol" || name == "ul" { listDepth += 1 }
            elements.append(Element(name: name, attributes: attributeDict, depth: open.count, listDepth: listDepth / 2))
            open.append(elements.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "li" || name == "ol" || name == "ul" { listDepth -= 1 }
            _ = open.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            for index in open { elements[index].text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let string = String(decoding: CDATABlock, as: UTF8.self)
            for index in open { elements[index].text += string }
        }
    }
}
