import Foundation

/// Other names for an item, as DEVONthink's aliases: `[[links]]` to any of
/// them reach it, and search finds it by them. Kept as text, one per line
/// or separated by commas or semicolons.
public enum Aliases {
    public static func split(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert(WikiLinks.key($0)).inserted }
    }

    public static func join(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }
}

/// DEVONthink's automatic wiki links: mentions of items' names in a note's
/// text, made into links when it's shown (never written into the note).
public enum AutoLink {
    /// A name to look for, and the title of the item it links to.
    public struct Name: Equatable {
        public var name: String
        public var title: String

        public init(name: String, title: String) {
            self.name = name
            self.title = title
        }
    }

    /// `text` with the first mention of each name made into a Markdown link
    /// `[mention](scheme://open?title=…)`. Whole words only, ignoring case,
    /// longest name first; not inside code, existing links or web addresses,
    /// and not in headings. Names under `minimumLength` letters are left out.
    public static func link(_ text: String, names: [Name], scheme: String, minimumLength: Int = 4) -> String {
        // Names by their first word, longest first, for a quick look-up at each word.
        var byFirstWord: [String: [(words: [String], title: String)]] = [:]
        for name in names where name.name.count >= minimumLength {
            let words = Self.words(name.name)
            guard let first = words.first else { continue }
            byFirstWord[first, default: []].append((words, name.title))
        }
        for key in byFirstWord.keys { byFirstWord[key]!.sort { $0.words.count > $1.words.count } }
        guard !byFirstWord.isEmpty else { return text }

        var linked: Set<String> = []
        var inFence = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            if inFence || trimmed.hasPrefix("#") || trimmed.hasPrefix("    ") { return line }
            return linkLine(line, byFirstWord: byFirstWord, linked: &linked, scheme: scheme)
        }
        return lines.joined(separator: "\n")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Ranges of a line that are code, links or addresses, left alone.
    private static func protectedRanges(in line: String) -> [Range<String.Index>] {
        let patterns = [#"`[^`]*`"#, #"\[\[[^\]]*\]\]"#, #"!?\[[^\]]*\]\([^)]*\)"#, #"<[^>]*>"#, #"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#]
        return patterns.flatMap { pattern -> [Range<String.Index>] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { Range($0.range, in: line) }
        }
    }

    private static func linkLine(_ line: String, byFirstWord: [String: [(words: [String], title: String)]],
                                 linked: inout Set<String>, scheme: String) -> String {
        let protected = protectedRanges(in: line)
        // Each word in the line, with where it is.
        var spans: [(word: String, range: Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index].isLetter || line[index].isNumber else { index = line.index(after: index); continue }
            let start = index
            while index < line.endIndex, line[index].isLetter || line[index].isNumber { index = line.index(after: index) }
            spans.append((line[start..<index].lowercased(), start..<index))
        }
        var result = ""
        var cursor = line.startIndex
        var position = 0
        while position < spans.count {
            let span = spans[position]
            var matched: (count: Int, title: String)?
            for candidate in byFirstWord[span.word] ?? [] where !linked.contains(WikiLinks.key(candidate.title)) {
                let end = position + candidate.words.count
                guard end <= spans.count, spans[position..<end].map(\.word) == candidate.words else { continue }
                let range = span.range.lowerBound..<spans[end - 1].range.upperBound
                guard !protected.contains(where: { $0.overlaps(range) }) else { continue }
                matched = (candidate.words.count, candidate.title)
                break
            }
            guard let matched else { position += 1; continue }
            let range = span.range.lowerBound..<spans[position + matched.count - 1].range.upperBound
            var components = URLComponents()
            components.scheme = scheme
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "title", value: matched.title)]
            let address = (components.url?.absoluteString ?? "").replacingOccurrences(of: ")", with: "%29")
            result += line[cursor..<range.lowerBound] + "[" + line[range] + "](" + address + ")"
            cursor = range.upperBound
            linked.insert(WikiLinks.key(matched.title))
            position += matched.count
        }
        return result + line[cursor...]
    }
}
