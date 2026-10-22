import Foundation

/// What's known about where something came from, for citing it: read from a
/// web page's metadata (Open Graph, Twitter, Dublin Core, Google Scholar's
/// `citation_` tags and schema.org JSON-LD), a PDF's properties, or typed in.
public struct Reference: Codable, Equatable {
    public var title = ""
    public var authors: [String] = []
    public var siteName = ""
    public var publisher = ""
    /// `2024-05-06`, or as much of it as is known (`2024-05`, `2024`).
    public var published = ""
    public var modified = ""
    public var url = ""
    public var description = ""
    public var image = ""
    /// article, website, book, video…
    public var type = ""
    public var language = ""
    public var keywords: [String] = []
    public var doi = ""
    public var journal = ""
    public var volume = ""
    public var issue = ""
    public var pages = ""
    /// When it was saved, as `2026-10-15`.
    public var accessed = ""

    public init() {}

    public init(json: String) {
        self = (try? JSONDecoder().decode(Reference.self, from: Data(json.utf8))) ?? Reference()
    }

    public var json: String {
        guard self != Reference() else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var isEmpty: Bool { self == Reference() }

    /// Fills what's empty here from `other`.
    public func merging(_ other: Reference) -> Reference {
        var result = self
        func fill(_ path: WritableKeyPath<Reference, String>) { if result[keyPath: path].isEmpty { result[keyPath: path] = other[keyPath: path] } }
        for path: WritableKeyPath<Reference, String> in [\.title, \.siteName, \.publisher, \.published, \.modified, \.url, \.description,
                                                        \.image, \.type, \.language, \.doi, \.journal, \.volume, \.issue, \.pages, \.accessed] {
            fill(path)
        }
        if result.authors.isEmpty { result.authors = other.authors }
        if result.keywords.isEmpty { result.keywords = other.keywords }
        return result
    }

    // MARK: - Reading a page

    public static func fromHTML(_ html: String, url: String) -> Reference {
        var meta: [String: [String]] = [:]
        let tagPattern = try! NSRegularExpression(pattern: "<(meta|link|html)\\b[^>]*>", options: [.caseInsensitive])
        let string = html as NSString
        var canonical = ""
        var language = ""
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: min(string.length, 400_000))) {
            let tag = string.substring(with: match.range)
            let attributes = HTMLText.attributes(of: tag)
            let name = string.substring(with: match.range(at: 1)).lowercased()
            if name == "html" {
                language = attributes["lang"] ?? language
            } else if name == "link" {
                if attributes["rel"]?.lowercased() == "canonical", let href = attributes["href"] { canonical = href }
            } else if let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                      let content = attributes["content"].map(HTMLText.decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty {
                meta[key, default: []].append(content)
            }
        }
        func first(_ keys: String...) -> String { keys.lazy.compactMap { meta[$0]?.first }.first ?? "" }
        func all(_ keys: String...) -> [String] { keys.lazy.compactMap { meta[$0] }.first ?? [] }

        var reference = Reference()
        reference.title = first("citation_title", "og:title", "twitter:title", "dc.title", "dcterms.title")
        if reference.title.isEmpty, let title = titleTag(html) { reference.title = title }
        reference.authors = all("citation_author", "author", "dc.creator", "dcterms.creator", "parsely-author", "sailthru.author", "article:author")
            .filter { !$0.hasPrefix("http") }
        reference.siteName = first("og:site_name", "application-name", "twitter:site").replacingOccurrences(of: "@", with: "")
        reference.publisher = first("citation_publisher", "dc.publisher", "dcterms.publisher")
        reference.published = date(first("citation_publication_date", "citation_date", "article:published_time", "datepublished",
                                         "dc.date", "dcterms.date", "dcterms.created", "pubdate", "date"))
        reference.modified = date(first("article:modified_time", "datemodified", "og:updated_time", "dcterms.modified"))
        reference.description = first("description", "og:description", "twitter:description", "dc.description")
        reference.image = first("og:image", "og:image:url", "twitter:image", "twitter:image:src")
        reference.type = first("og:type")
        reference.language = language.isEmpty ? first("og:locale", "dc.language") : language
        reference.keywords = all("article:tag").isEmpty
            ? first("keywords", "news_keywords").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : all("article:tag")
        reference.doi = first("citation_doi", "prism.doi", "dc.identifier").replacingOccurrences(of: "doi:", with: "")
        if !reference.doi.hasPrefix("10.") { reference.doi = "" }
        reference.journal = first("citation_journal_title", "prism.publicationname")
        reference.volume = first("citation_volume", "prism.volume")
        reference.issue = first("citation_issue", "prism.number")
        let firstPage = first("citation_firstpage"), lastPage = first("citation_lastpage")
        reference.pages = lastPage.isEmpty ? firstPage : firstPage + "–" + lastPage
        reference.url = canonical.isEmpty ? url : canonical
        return reference.merging(fromJSONLD(html))
    }

    private static func titleTag(_ html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let open = html[start.upperBound...].firstIndex(of: ">"),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: open..<html.endIndex) else { return nil }
        let title = HTMLText.decodeEntities(String(html[html.index(after: open)..<end.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// schema.org's description of the page, in `<script type="application/ld+json">`.
    static func fromJSONLD(_ html: String) -> Reference {
        let pattern = try! NSRegularExpression(pattern: "<script[^>]*application/ld\\+json[^>]*>(.*?)</script>",
                                               options: [.caseInsensitive, .dotMatchesLineSeparators])
        let string = html as NSString
        var reference = Reference()
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: string.length)) {
            let body = string.substring(with: match.range(at: 1))
            guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { continue }
            var nodes: [[String: Any]] = []
            func collect(_ value: Any) {
                if let dictionary = value as? [String: Any] {
                    nodes.append(dictionary)
                    if let graph = dictionary["@graph"] { collect(graph) }
                } else if let array = value as? [Any] {
                    array.forEach(collect)
                }
            }
            collect(object)
            let articleTypes = ["article", "newsarticle", "blogposting", "scholarlyarticle", "report", "techarticle", "webpage", "book", "creativework"]
            for node in nodes {
                let types = ((node["@type"] as? String).map { [$0] } ?? (node["@type"] as? [String]) ?? []).map { $0.lowercased() }
                guard types.contains(where: articleTypes.contains) else { continue }
                var found = Reference()
                found.title = (node["headline"] as? String) ?? (node["name"] as? String) ?? ""
                found.authors = names(node["author"])
                found.publisher = names(node["publisher"]).first ?? ""
                found.published = date((node["datePublished"] as? String) ?? "")
                found.modified = date((node["dateModified"] as? String) ?? "")
                found.description = (node["description"] as? String) ?? ""
                found.type = types.first ?? ""
                if let image = node["image"] as? String { found.image = image } else if let image = (node["image"] as? [String: Any])?["url"] as? String {
                    found.image = image
                }
                // Articles first; a plain WebPage only fills gaps.
                reference = types.contains("webpage") ? reference.merging(found) : found.merging(reference)
            }
        }
        return reference
    }

    private static func names(_ value: Any?) -> [String] {
        if let name = value as? String { return [name] }
        if let person = value as? [String: Any], let name = person["name"] as? String { return [name] }
        if let list = value as? [Any] { return list.flatMap { names($0) } }
        return []
    }

    /// The date part of a date as written: 2024-05-06T10:00 → 2024-05-06; 2024/5/6 → 2024-05-06.
    public static func date(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.prefix(10).split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
        guard let year = parts.first.flatMap(Int.init), (1000...9999).contains(year) else { return "" }
        let month = parts.count > 1 ? Int(parts[1]) : nil
        let day = parts.count > 2 ? Int(parts[2].prefix(2)) : nil
        switch (month, day) {
        case let (month?, day?) where (1...12).contains(month) && (1...31).contains(day): return String(format: "%04d-%02d-%02d", year, month, day)
        case let (month?, _) where (1...12).contains(month): return String(format: "%04d-%02d", year, month)
        default: return String(year)
        }
    }

    // MARK: - Citing

    public enum Style: String, CaseIterable, Identifiable, Codable {
        case apa, mla, chicago

        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .apa: "APA"
            case .mla: "MLA"
            case .chicago: "Chicago"
            }
        }
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    private struct DateParts { var year: Int?; var month: Int?; var day: Int? }

    private static func parts(_ date: String) -> DateParts {
        let numbers = date.split(separator: "-").compactMap { Int($0) }
        return DateParts(year: numbers.first, month: numbers.count > 1 ? numbers[1] : nil, day: numbers.count > 2 ? numbers[2] : nil)
    }

    /// "Ann B. Smith" → (last: "Smith", given: "Ann B.").
    private static func split(_ name: String) -> (last: String, given: String) {
        if name.contains(",") {
            let pieces = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (pieces[0], pieces.count > 1 ? pieces[1] : "")
        }
        var words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (name, "") }
        let last = words.removeLast()
        return (last, words.joined(separator: " "))
    }

    private static func initials(_ given: String) -> String {
        given.split(separator: " ").compactMap { $0.first.map { "\($0)." } }.joined(separator: " ")
    }

    private var source: String { journal.isEmpty ? (siteName.isEmpty ? publisher : siteName) : journal }
    private var link: String { doi.isEmpty ? url : "https://doi.org/" + doi }

    public func citation(_ style: Style) -> String {
        let date = Self.parts(published)
        let name = title.isEmpty ? "Untitled" : title
        switch style {
        case .apa:
            let people = authors.map { author -> String in
                let (last, given) = Self.split(author)
                return given.isEmpty ? last : "\(last), \(Self.initials(given))"
            }
            let who: String
            switch people.count {
            case 0: who = ""
            case 1: who = people[0]
            case 2: who = people[0] + ", & " + people[1]
            default: who = people.dropLast().joined(separator: ", ") + ", & " + people.last!
            }
            var when = "n.d."
            if let year = date.year {
                when = String(year)
                if let month = date.month { when += ", " + Self.months[month - 1] + (date.day.map { " \($0)" } ?? "") }
            }
            var parts: [String] = []
            if who.isEmpty {
                parts = ["\(name). (\(when))."]
            } else {
                parts = [who.hasSuffix(".") ? who : who + ".", "(\(when)).", journal.isEmpty ? "*\(name)*." : "\(name)."]
            }
            if !journal.isEmpty {
                var journalPart = "*\(journal)*"
                if !volume.isEmpty { journalPart += ", *\(volume)*" + (issue.isEmpty ? "" : "(\(issue))") }
                if !pages.isEmpty { journalPart += ", " + pages }
                parts.append(journalPart + ".")
            } else if !source.isEmpty {
                parts.append(source + ".")
            }
            if !link.isEmpty { parts.append(link) }
            return parts.joined(separator: " ")
        case .mla:
            var who = ""
            if let firstAuthor = authors.first {
                let (last, given) = Self.split(firstAuthor)
                who = given.isEmpty ? last : "\(last), \(given)"
                if authors.count == 2 { who += ", and " + authors[1] } else if authors.count > 2 { who += ", et al" }
                who += "."
            }
            var parts = [who, "“\(name).”"].filter { !$0.isEmpty }
            if !source.isEmpty { parts.append("*\(source)*,") }
            if let year = date.year {
                let when = [date.day.map(String.init), date.month.map { String(Self.months[$0 - 1].prefix(3)) + ($0 == 5 ? "" : ".") }, String(year)]
                    .compactMap { $0 }.joined(separator: " ")
                parts.append(when + ",")
            }
            if !link.isEmpty { parts.append(link.replacingOccurrences(of: "https://", with: "") + ".") }
            if !accessed.isEmpty, let year = Self.parts(accessed).year, let month = Self.parts(accessed).month {
                parts.append("Accessed \(Self.parts(accessed).day.map { "\($0) " } ?? "")\(Self.months[month - 1].prefix(3)). \(year).")
            }
            var text = parts.joined(separator: " ")
            if text.hasSuffix(",") { text = String(text.dropLast()) + "." }
            return text
        case .chicago:
            var who = ""
            if let firstAuthor = authors.first {
                let (last, given) = Self.split(firstAuthor)
                who = given.isEmpty ? last : "\(last), \(given)"
                if authors.count > 1 { who += (authors.count == 2 ? " and " : ", et al") + (authors.count == 2 ? authors[1] : "") }
                who += "."
            }
            var parts = [who, "“\(name).”"].filter { !$0.isEmpty }
            if !source.isEmpty { parts.append(source + ".") }
            if let year = date.year {
                parts.append(([date.month.map { Self.months[$0 - 1] + (date.day.map { " \($0)," } ?? "") }].compactMap { $0 } + [String(year)])
                    .joined(separator: " ") + ".")
            }
            if !link.isEmpty { parts.append(link + ".") }
            return parts.joined(separator: " ")
        }
    }

    /// A BibTeX entry, for LaTeX and reference managers.
    public func bibTeX(key: String) -> String {
        let date = Self.parts(published)
        var fields: [(String, String)] = [("title", title)]
        if !authors.isEmpty { fields.append(("author", authors.joined(separator: " and "))) }
        if !journal.isEmpty { fields.append(("journal", journal)) } else if !source.isEmpty { fields.append(("howpublished", source)) }
        if let year = date.year { fields.append(("year", String(year))) }
        if let month = date.month { fields.append(("month", String(month))) }
        if !volume.isEmpty { fields.append(("volume", volume)) }
        if !issue.isEmpty { fields.append(("number", issue)) }
        if !pages.isEmpty { fields.append(("pages", pages.replacingOccurrences(of: "–", with: "--"))) }
        if !doi.isEmpty { fields.append(("doi", doi)) }
        if !url.isEmpty { fields.append(("url", url)) }
        if !accessed.isEmpty { fields.append(("urldate", accessed)) }
        let kind = journal.isEmpty ? "misc" : "article"
        return "@\(kind){\(key),\n" + fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n") + "\n}"
    }
}

/// Highlights from several items, as one Markdown document with references:
/// each source's highlights under its title, footnoted to its citation.
public enum HighlightDigest {
    public struct Source {
        public var title: String
        public var reference: Reference
        public var link: String
        public var highlights: [Highlight]

        public init(title: String, reference: Reference, link: String, highlights: [Highlight]) {
            self.title = title
            self.reference = reference
            self.link = link
            self.highlights = highlights
        }
    }

    public struct Highlight {
        public var text: String
        public var note: String
        /// From 1, for PDFs.
        public var page: Int?

        public init(text: String, note: String = "", page: Int? = nil) {
            self.text = text
            self.note = note
            self.page = page
        }
    }

    public static func markdown(title: String, sources: [Source], style: Reference.Style, date: String) -> String {
        var lines = ["# \(title)", "", "*Highlights from \(sources.count) \(sources.count == 1 ? "source" : "sources"), \(date).*", ""]
        for (index, source) in sources.enumerated() where !source.highlights.isEmpty {
            let mark = "[^\(index + 1)]"
            lines.append("## \(source.title)")
            lines.append("")
            for highlight in source.highlights {
                let text = highlight.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                let page = highlight.page.map { " (p. \($0))" } ?? ""
                lines.append("> \(text)\(page) \(mark)")
                lines.append("")
                if !highlight.note.isEmpty {
                    lines.append(highlight.note)
                    lines.append("")
                }
            }
        }
        lines.append("## References")
        lines.append("")
        for (index, source) in sources.enumerated() where !source.highlights.isEmpty {
            var reference = source.reference
            if reference.title.isEmpty { reference.title = source.title }
            lines.append("[^\(index + 1)]: \(reference.citation(style)) [Open in Stash](\(source.link))")
        }
        return lines.joined(separator: "\n")
    }
}
