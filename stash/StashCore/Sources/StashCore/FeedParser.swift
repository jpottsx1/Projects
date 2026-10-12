import Foundation

/// A web feed, read: RSS (0.9x, 1.0 and 2.0), Atom or JSON Feed.
public struct ParsedFeed: Equatable {
    public var title: String
    /// The site the feed belongs to.
    public var siteURL: URL?
    public var entries: [Entry]

    public struct Entry: Equatable {
        /// What the feed calls it, to know it next time: its guid or id,
        /// or else its link.
        public var id: String
        public var title: String
        public var link: URL?
        /// A line or two about it, as plain text.
        public var summary: String
        /// The whole post as HTML, when the feed carries it.
        public var html: String
        public var published: Date?
    }
}

public enum FeedParser {
    /// Nil when the data isn't a feed -- a web page, say, which may say
    /// where its feed is (see `feedLinks(inHTML:base:)`).
    public static func parse(_ data: Data, from url: URL? = nil) -> ParsedFeed? {
        let start = data.prefix(512)
        let head = String(decoding: start, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("{") { return json(data, base: url) }
        guard let root = XMLNode.parse(data) else { return nil }
        switch root.name.lowercased() {
        case "rss":
            guard let channel = root.child("channel") else { return nil }
            return rss(channel: channel, items: channel.children("item"), base: url)
        case "rdf:rdf", "rdf":
            guard let channel = root.child("channel") else { return nil }
            return rss(channel: channel, items: root.children("item"), base: url)
        case "feed":
            return atom(root, base: url)
        default:
            return nil
        }
    }

    // MARK: - RSS

    private static func rss(channel: XMLNode, items: [XMLNode], base: URL?) -> ParsedFeed {
        let entries: [ParsedFeed.Entry] = items.compactMap { item in
            let link = item.string("link").flatMap { resolve($0, base) }
                ?? item.child("guid").flatMap { guid in
                    guid.attribute("isPermaLink")?.lowercased() == "false" ? nil : resolve(guid.text.trimmed, base)
                }
            let html = item.string("content:encoded") ?? item.string("description") ?? ""
            let title = item.string("title").map(plain) ?? ""
            guard let id = item.string("guid") ?? link?.absoluteString ?? (title.isEmpty ? nil : title) else { return nil }
            return ParsedFeed.Entry(
                id: id, title: title, link: link,
                summary: summary(item.string("description") ?? html),
                html: html,
                published: (item.string("pubDate") ?? item.string("dc:date")).flatMap(date))
        }
        return ParsedFeed(title: channel.string("title").map(plain) ?? "",
                          siteURL: channel.string("link").flatMap { resolve($0, base) },
                          entries: entries)
    }

    // MARK: - Atom

    private static func atom(_ feed: XMLNode, base: URL?) -> ParsedFeed {
        func link(of node: XMLNode) -> URL? {
            let links = node.children("link")
            let chosen = links.first { ($0.attribute("rel") ?? "alternate").lowercased() == "alternate" } ?? links.first
            return chosen?.attribute("href").flatMap { resolve($0, base) }
        }
        let entries: [ParsedFeed.Entry] = feed.children("entry").compactMap { entry in
            let link = link(of: entry)
            let title = entry.string("title").map(plain) ?? ""
            let html = entry.string("content") ?? entry.string("summary") ?? ""
            guard let id = entry.string("id") ?? link?.absoluteString else { return nil }
            return ParsedFeed.Entry(
                id: id, title: title, link: link,
                summary: summary(entry.string("summary") ?? html),
                html: html,
                published: (entry.string("published") ?? entry.string("updated")).flatMap(date))
        }
        return ParsedFeed(title: feed.string("title").map(plain) ?? "", siteURL: link(of: feed), entries: entries)
    }

    // MARK: - JSON Feed

    private struct JSONFeed: Decodable {
        var title: String?
        var home_page_url: String?
        var items: [Item]?
        struct Item: Decodable {
            var id: String?
            var url: String?
            var title: String?
            var summary: String?
            var content_html: String?
            var content_text: String?
            var date_published: String?
        }
    }

    private static func json(_ data: Data, base: URL?) -> ParsedFeed? {
        guard let feed = try? JSONDecoder().decode(JSONFeed.self, from: data), let items = feed.items else { return nil }
        let entries: [ParsedFeed.Entry] = items.compactMap { item in
            let link = item.url.flatMap { resolve($0, base) }
            guard let id = item.id ?? link?.absoluteString else { return nil }
            let html = item.content_html ?? item.content_text.map(MarkdownHTML.escape) ?? ""
            return ParsedFeed.Entry(
                id: id, title: item.title.map(plain) ?? "", link: link,
                summary: summary(item.summary ?? html), html: html,
                published: item.date_published.flatMap(date))
        }
        return ParsedFeed(title: feed.title ?? "", siteURL: feed.home_page_url.flatMap { resolve($0, base) },
                          entries: entries)
    }

    // MARK: - Finding a site's feed

    /// The feeds a web page says it has, in the order it lists them.
    public static func feedLinks(inHTML html: String, base: URL?) -> [URL] {
        let types = ["application/rss+xml", "application/atom+xml", "application/feed+json", "application/json"]
        let regex = try! NSRegularExpression(pattern: #"<link\s[^>]*>"#, options: [.caseInsensitive])
        let string = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: string.length)).compactMap { match in
            let attributes = HTMLText.attributes(of: string.substring(with: match.range))
            guard attributes["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                  let type = attributes["type"]?.lowercased(), types.contains(type),
                  let href = attributes["href"] else { return nil }
            return resolve(HTMLText.decodeEntities(href), base)
        }
    }

    // MARK: - Helpers

    private static func resolve(_ string: String, _ base: URL?) -> URL? {
        let trimmed = string.trimmed
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Text that may be HTML, as plain text.
    private static func plain(_ text: String) -> String {
        text.contains("<") || text.contains("&") ? HTMLText.extract(from: text).text : text.trimmed
    }

    private static func summary(_ html: String) -> String {
        let text = plain(html)
        guard text.count > 300 else { return text }
        let cut = text.prefix(300)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// RFC 822 dates (RSS) and ISO 8601 ones (Atom, JSON Feed, Dublin Core).
    public static func date(_ string: String) -> Date? {
        let text = string.trimmed
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
