import Foundation

/// Markdown files written elsewhere -- Obsidian, Bear, iA Writer, Apple
/// Notes exporters -- as Stash notes: the title, tags and dates their
/// front matter gives, and the pictures beside them.
public enum MarkdownImport {
    public struct Note: Equatable {
        public var title: String
        public var body: String
        public var tags: [String] = []
        public var created: Date?
        public var modified: Date?
    }

    public static func note(fromMarkdown text: String, fileName: String) -> Note {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var note = Note(title: "", body: "")
        let fields = frontMatter(&body)

        note.title = fields["title"].map(unquote) ?? ""
        for key in ["tags", "tag", "keywords"] {
            if let value = fields[key] { note.tags += list(value) }
        }
        note.created = ["created", "date", "created_at", "creation date"].lazy.compactMap { fields[$0].flatMap(date) }.first
        note.modified = ["updated", "modified", "updated_at", "last modified"].lazy.compactMap { fields[$0].flatMap(date) }.first

        // A first-line heading is the title, unless there's one already.
        var lines = body.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        let fallback = (fileName as NSString).deletingPathExtension
        if let first = lines.first, first.hasPrefix("# ") {
            let heading = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if note.title.isEmpty || note.title == heading {
                note.title = heading
                lines.removeFirst()
                while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            }
        }
        if note.title.isEmpty { note.title = fallback }
        note.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return note
    }

    /// Takes `---` front matter off the top of the text, as its fields.
    /// Simple YAML only: `key: value`, and lists either `[a, b]` or as
    /// `- item` lines.
    static func frontMatter(_ text: inout String) -> [String: String] {
        guard text.hasPrefix("---\n") else { return [:] }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) })
        else { return [:] }
        var fields: [String: String] = [:]
        var lastKey: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = lastKey {
                let item = String(trimmed.dropFirst(2))
                fields[key] = (fields[key].map { $0.isEmpty ? "" : $0 + ", " } ?? "") + item
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
            lastKey = key
        }
        text = lines[(end + 1)...].joined(separator: "\n")
        return fields
    }

    private static func unquote(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func list(_ value: String) -> [String] {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value.split(whereSeparator: { $0 == "," || $0 == " " && !value.contains(",") })
            .map { unquote(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }
    }

    static func date(_ value: String) -> Date? {
        let text = unquote(value)
        if let date = FeedParser.date(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Pictures

    private static let picturePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\((<[^>\n]+>|[^)\s]+)(?:\s+"[^"\n]*")?\)|!\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]"#)

    /// Each picture the text shows from a file beside it (`![](images/a.png)`,
    /// or Obsidian's `![[a.png]]`), replaced by what `replacement` returns for
    /// its path -- percent-decoded, relative to the note. Pictures on the web,
    /// and any `replacement` returns nil for, stay as they are.
    public static func replacingLocalPictures(in text: String, with replacement: (String) -> String?) -> String {
        let string = text as NSString
        var result = ""
        var cursor = 0
        for match in picturePattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var path: String
            if match.range(at: 2).location != NSNotFound {
                path = string.substring(with: match.range(at: 2))
                if path.hasPrefix("<") { path = String(path.dropFirst().dropLast()) }
            } else {
                path = string.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            }
            let lowered = path.lowercased()
            guard !["http:", "https:", "data:", "attachment:"].contains(where: lowered.hasPrefix) else { continue }
            path = path.removingPercentEncoding ?? path
            if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
            guard let markdown = replacement(path) else { continue }
            result += string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += markdown
            cursor = match.range.location + match.range.length
        }
        result += string.substring(from: cursor)
        return result
    }

    /// File types read as notes.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]
    public static let htmlExtensions: Set<String> = ["html", "htm"]

    /// The title of an exported HTML page, and its body as Markdown.
    public static func note(fromHTML html: String, fileName: String,
                            picture: (HTMLMarkdown.Picture) -> String? = HTMLMarkdown.defaultPicture) -> Note {
        let page = HTMLText.extract(from: String(html.prefix(20_000)))
        var body = HTMLMarkdown.convert(html, picture: picture)
        let fallback = (fileName as NSString).deletingPathExtension
        var title = page.title?.trimmingCharacters(in: .whitespaces) ?? ""
        // The heading that starts the page is usually the title again.
        if body.hasPrefix("# ") {
            let firstLine = String(body.prefix { $0 != "\n" }.dropFirst(2))
            if title.isEmpty || title == firstLine {
                title = firstLine
                body = String(body.dropFirst(body.prefix { $0 != "\n" }.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return Note(title: title.isEmpty ? fallback : title, body: body)
    }
}
