import Foundation

/// `[[Title]]` links between items, written inside a note's Markdown.
///
/// `[[Title|shown text]]` links to `Title` but reads as "shown text". Titles
/// match case-insensitively, so `[[shopping list]]` finds "Shopping List".
public enum WikiLinks {
    public struct Link: Equatable {
        public var range: Range<String.Index>
        public var target: String
        public var label: String?
    }

    // No brackets, pipes or line breaks in a target, so a stray "[[" can
    // never swallow the rest of a note.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[\[([^\[\]|\n]+?)(?:\|([^\[\]\n]*))?\]\]"#)

    public static func links(in text: String) -> [Link] {
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let targetRange = Range(match.range(at: 1), in: text) else { return nil }
            let target = text[targetRange].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            var label: String?
            if let labelRange = Range(match.range(at: 2), in: text) {
                let trimmed = text[labelRange].trimmingCharacters(in: .whitespaces)
                label = trimmed.isEmpty ? nil : trimmed
            }
            return Link(range: range, target: target, label: label)
        }
    }

    /// The titles `text` links to, in order of first appearance, each once.
    public static func titles(in text: String) -> [String] {
        var seen = Set<String>()
        return links(in: text).map(\.target).filter { seen.insert(key($0)).inserted }
    }

    /// What two titles are compared by.
    public static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: nil)
    }

    /// `text` with every link to `old` pointing at `new`, keeping any shown text.
    /// Used when an item is renamed, so links to it keep working.
    public static func renaming(_ old: String, to new: String, in text: String) -> String {
        let oldKey = key(old)
        return rewriting(text) { link in
            guard key(link.target) == oldKey else { return nil }
            return link.label.map { "[[\(new)|\($0)]]" } ?? "[[\(new)]]"
        }
    }

    /// `text` with each wiki link turned into an ordinary Markdown link to
    /// `scheme://open?title=...`, so a Markdown renderer makes it tappable.
    public static func markdownLinks(in text: String, scheme: String) -> String {
        rewriting(text) { link in
            "[\(link.label ?? link.target)](\(url(for: link.target, scheme: scheme)))"
        }
    }

    public static func url(for title: String, scheme: String) -> String {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title
        return "\(scheme)://open?title=\(encoded)"
    }

    /// The title a link made by `url(for:scheme:)` points at.
    public static func title(from url: URL, scheme: String) -> String? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "title" }?.value
    }

    /// Walks the links front to back, replacing each one `replacement` returns
    /// text for. Built forwards rather than edited in place, so no index is
    /// used after the string it came from has changed.
    private static func rewriting(_ text: String, _ replacement: (Link) -> String?) -> String {
        var result = ""
        var cursor = text.startIndex
        for link in links(in: text) {
            guard let new = replacement(link) else { continue }
            result += text[cursor..<link.range.lowerBound]
            result += new
            cursor = link.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Unlinked mentions

    /// Where `title` appears in `text` as whole words, ignoring case, but
    /// not already inside a `[[link]]` -- places a link could go.
    public static func unlinkedMentions(of title: String, in text: String) -> [Range<String.Index>] {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let linked = linkRanges(in: text)
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let wordBefore = before.map { $0.isLetter || $0.isNumber } ?? false
            let wordAfter = after.map { $0.isLetter || $0.isNumber } ?? false
            guard !wordBefore, !wordAfter,
                  !linked.contains(where: { $0.overlaps(range) }) else { continue }
            found.append(range)
        }
        return found
    }

    /// `text` with each unlinked mention of `title` made into a link to it,
    /// keeping the words as they were written: `[[Title|title]]` when the
    /// case differs.
    public static func linkingMentions(of title: String, in text: String) -> String {
        var result = text
        for range in unlinkedMentions(of: title, in: text).reversed() {
            let written = String(text[range])
            result.replaceSubrange(range, with: written == title ? "[[\(title)]]" : "[[\(title)|\(written)]]")
        }
        return result
    }

    private static func linkRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "[[", range: searchStart..<text.endIndex),
              let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            ranges.append(open.lowerBound..<close.upperBound)
            searchStart = close.upperBound
        }
        return ranges
    }
}
