import Foundation

/// Highlights and their notes as Markdown, as DEVONthink's annotation
/// files are: one item's, as a note of their own linked to it, or the
/// whole library's, to export.
public enum AnnotationSummary {
    public struct Entry: Equatable {
        public var text: String
        public var note: String
        public var color: HighlightColor
        /// Where it is: "p. 12", "Chapter 3"; nil when there's nothing to say.
        public var location: String?

        public init(text: String, note: String = "", color: HighlightColor = .yellow, location: String? = nil) {
            self.text = text
            self.note = note
            self.color = color
            self.location = location
        }
    }

    public struct Source: Equatable {
        public var title: String
        /// The web page or book it came from, if it's somewhere.
        public var url: String?
        public var entries: [Entry]

        public init(title: String, url: String? = nil, entries: [Entry]) {
            self.title = title
            self.url = url
            self.entries = entries
        }
    }

    /// A marker for each colour, which reads the same anywhere Markdown goes.
    public static func marker(_ color: HighlightColor) -> String {
        switch color {
        case .yellow: "🟨"
        case .green: "🟩"
        case .blue: "🟦"
        case .pink: "🩷"
        case .purple: "🟪"
        }
    }

    /// Where a highlight is, from its anchor and position: PDF pages and
    /// book chapters, counted from one.
    public static func location(of anchor: HighlightAnchor?, position: Double) -> String? {
        switch anchor {
        case .pdf(let pages)?:
            return pages.first.map { "p. \($0.page + 1)" }
        case .epub?:
            return "Chapter \(Int(position) + 1)"
        default:
            return nil
        }
    }

    /// The highlights, each a quote with its place under it, then its note.
    public static func entries(_ entries: [Entry]) -> String {
        entries.map { entry in
            var block = entry.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .enumerated()
                .map { number, line in "> " + (number == 0 ? marker(entry.color) + " " : "") + line }
                .joined(separator: "\n")
            if let location = entry.location { block += "\n\n_\(location)_" }
            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { block += "\n\n" + note }
            return block
        }.joined(separator: "\n\n")
    }

    /// One item's summary note: where it's from (a `[[link]]` to the item
    /// and its address), then the highlights.
    public static func note(for source: Source) -> String {
        var lines = ["From [[\(source.title)]]" + (source.url.map { " · [\(host($0))](\($0))" } ?? "")]
        lines.append("")
        lines.append(entries(source.entries))
        return lines.joined(separator: "\n")
    }

    /// The summary note's title.
    public static func noteTitle(for title: String) -> String {
        "Highlights: " + title
    }

    /// Every item's highlights in one document, an item to a heading.
    public static func library(_ sources: [Source], exportedAt date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let count = sources.reduce(0) { $0 + $1.entries.count }
        var parts = ["# Highlights",
                     "\(count) highlight\(count == 1 ? "" : "s") from \(sources.count) item\(sources.count == 1 ? "" : "s"), \(formatter.string(from: date))."]
        for source in sources where !source.entries.isEmpty {
            var heading = "## " + source.title
            if let url = source.url { heading += "\n\n[\(host(url))](\(url))" }
            parts.append(heading)
            parts.append(entries(source.entries))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func host(_ address: String) -> String {
        URL(string: address)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? address
    }
}
