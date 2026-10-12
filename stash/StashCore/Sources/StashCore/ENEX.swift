import Foundation

/// An Evernote export (.enex): one notebook's notes, each with its title,
/// dates, tags and attachments, the text in Evernote's HTML (ENML).
public enum ENEX {
    public struct Note: Equatable {
        public var title: String
        /// ENML: XHTML in an `<en-note>`.
        public var content: String
        public var created: Date?
        public var updated: Date?
        public var tags: [String]
        /// Where a clipped page came from.
        public var sourceURL: String?
        public var resources: [Resource]
    }

    public struct Resource: Equatable {
        public var data: Data
        public var mimeType: String
        public var fileName: String?
        /// MD5 of the data, as hex: what the note's `<en-media hash>` names.
        public var hash: String

        public var isPicture: Bool { mimeType.lowercased().hasPrefix("image/") }

        /// What to call the file: its own name, or one made from its type.
        public var suggestedName: String {
            if let fileName, !fileName.isEmpty { return fileName }
            let ext = mimeType.split(separator: "/").last.map(String.init) ?? "bin"
            return "Attachment." + (ext == "jpeg" ? "jpg" : ext)
        }
    }

    /// Nil when the data isn't an Evernote export.
    public static func parse(_ data: Data) -> [Note]? {
        guard let root = XMLNode.parse(data), root.name.lowercased() == "en-export" else { return nil }
        return root.children("note").map { note in
            let attributes = note.child("note-attributes")
            return Note(
                title: note.string("title") ?? "",
                content: note.child("content")?.text ?? "",
                created: note.string("created").flatMap(date),
                updated: note.string("updated").flatMap(date),
                tags: note.children("tag").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                sourceURL: attributes?.string("source-url"),
                resources: note.children("resource").compactMap(resource))
        }
    }

    private static func resource(_ node: XMLNode) -> Resource? {
        guard let encoded = node.child("data")?.text,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
        return Resource(data: data, mimeType: node.string("mime") ?? "application/octet-stream",
                        fileName: node.child("resource-attributes")?.string("file-name"),
                        hash: MD5.hex(data))
    }

    /// Evernote's dates: 20230115T093000Z.
    public static func date(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The note's text as Markdown. `attachment` is asked for each
    /// attachment the text shows, and returns the Markdown for it.
    public static func markdown(of note: Note, attachment: (Resource) -> String?) -> String {
        let byHash = Dictionary(note.resources.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var body = HTMLMarkdown.convert(note.content) { picture in
            if picture.tag == "en-media" {
                guard let hash = picture.attributes["hash"]?.lowercased(), let resource = byHash[hash] else { return nil }
                return attachment(resource)
            }
            return HTMLMarkdown.defaultPicture(picture)
        }
        // Attachments the text doesn't show still come along, at the end.
        let shown = Set(note.content.lowercased().components(separatedBy: "hash=\"").dropFirst().map { String($0.prefix(32)) })
        let unshown = note.resources.filter { !shown.contains($0.hash) }.compactMap(attachment)
        if !unshown.isEmpty { body += (body.isEmpty ? "" : "\n\n") + unshown.joined(separator: "\n") }
        if let source = note.sourceURL, !source.isEmpty { body += (body.isEmpty ? "" : "\n\n") + "Source: [\(source)](\(source))" }
        return body
    }
}
