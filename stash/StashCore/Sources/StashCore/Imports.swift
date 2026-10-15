import Foundation

/// Read-later and bookmarking services' CSV exports -- Pocket, Instapaper,
/// Raindrop and the like -- read by their column headings.
public enum LinkExport {
    /// Nil when the text isn't a CSV with a URL column.
    public static func parse(csv text: String) -> [BookmarksFile.Bookmark]? {
        let sheet = Sheet(text: text)
        let headings = sheet.headings.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { headings.firstIndex { names.contains($0) } }
        guard let urlColumn = column(["url", "link", "href", "address"]) else { return nil }
        let titleColumn = column(["title", "name"])
        let tagsColumn = column(["tags", "labels", "tag"])
        let folderColumn = column(["folder", "collection", "category", "list"])
        let dateColumn = column(["time_added", "created", "timestamp", "date", "added", "date added", "created_at"])
        let noteColumns = ["note", "excerpt", "description", "selection", "notes"].compactMap { name in headings.firstIndex(of: name) }

        var bookmarks: [BookmarksFile.Bookmark] = []
        for row in sheet.rows.dropFirst() {
            func value(_ index: Int?) -> String { index.map { row[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard let url = URL(string: value(urlColumn)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let title = value(titleColumn)
            let folder = value(folderColumn)
            // "Unread" and "Archive" are Instapaper's and Pocket's states, not folders.
            let folders = ["", "unread", "archive", "archived", "read"].contains(folder.lowercased())
                ? [] : folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var bookmark = BookmarksFile.Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url,
                                                  added: date(value(dateColumn)), folders: folders, tags: tags(value(tagsColumn)))
            bookmark.note = noteColumns.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            bookmarks.append(bookmark)
        }
        return bookmarks
    }

    /// `a,b`, `a|b` (Pocket), or `["a","b"]` (Instapaper).
    static func tags(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return trimmed.split(whereSeparator: { $0 == "," || $0 == "|" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }
    }

    /// Seconds since 1970 (Pocket, Instapaper) or an ISO 8601 date (Raindrop).
    static func date(_ text: String) -> Date? {
        if let seconds = Double(text), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// OPML: the list of feeds feed readers import and export.
public enum OPML {
    public struct Feed: Equatable {
        public var title: String
        public var url: String
        /// The folders it's in, outermost first.
        public var folders: [String]

        public init(title: String, url: String, folders: [String] = []) {
            self.title = title
            self.url = url
            self.folders = folders
        }
    }

    public static func parse(_ data: Data) -> [Feed] {
        guard let root = XMLNode.parse(data), let body = root.child("body") else { return [] }
        var feeds: [Feed] = []
        func walk(_ node: XMLNode, folders: [String]) {
            for outline in node.children("outline") {
                let title = outline.attribute("title") ?? outline.attribute("text") ?? ""
                if let url = outline.attribute("xmlUrl") ?? outline.attribute("xmlurl"), !url.isEmpty {
                    feeds.append(Feed(title: title, url: url, folders: folders))
                } else {
                    walk(outline, folders: title.isEmpty ? folders : folders + [title])
                }
            }
        }
        walk(body, folders: [])
        return feeds
    }

    public static func write(_ feeds: [Feed], title: String = "Stash Feeds") -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<opml version=\"2.0\">",
                     "  <head><title>\(escape(title))</title></head>", "  <body>"]
        let grouped = Dictionary(grouping: feeds) { $0.folders.first ?? "" }
        for folder in grouped.keys.sorted() {
            let indent = folder.isEmpty ? "    " : "      "
            if !folder.isEmpty { lines.append("    <outline text=\"\(escape(folder))\" title=\"\(escape(folder))\">") }
            for feed in grouped[folder] ?? [] {
                lines.append("\(indent)<outline type=\"rss\" text=\"\(escape(feed.title))\" title=\"\(escape(feed.title))\" xmlUrl=\"\(escape(feed.url))\"/>")
            }
            if !folder.isEmpty { lines.append("    </outline>") }
        }
        lines += ["  </body>", "</opml>"]
        return lines.joined(separator: "\n")
    }
}

extension MarkdownImport {
    /// A TextBundle's text (as Bear and Ulysses export): the bundle's name
    /// for the note's, and the folder it's in for its category.
    public static func textBundle(_ path: String) -> (name: String, folder: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let index = parts.lastIndex(where: { $0.lowercased().hasSuffix(".textbundle") }),
              index == parts.count - 2, parts.last?.lowercased().hasPrefix("text.") == true else { return nil }
        let name = (parts[index] as NSString).deletingPathExtension
        return (name, parts[..<index].joined(separator: "/"))
    }

    /// Files inside a TextBundle that aren't its text or its pictures.
    public static func isTextBundleExtra(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard parts.count >= 2, parts[parts.count - 2].hasSuffix(".textbundle") else { return false }
        return parts.last == "info.json"
    }
}
