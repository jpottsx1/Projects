import Foundation

// MARK: - Quick Open

/// Finding an item or place by typing a little of its name, as Quick Open
/// does: the letters in order, anywhere, with starts of words and runs of
/// letters counting for more.
public enum QuickOpen {
    /// How well `query` matches `name`; nil when it doesn't. Higher is better.
    public static func score(_ query: String, _ name: String) -> Int? {
        let wanted = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !wanted.isEmpty else { return 0 }
        let letters = Array(name.lowercased())
        var score = 0
        var position = 0
        var previous: Int?
        for character in wanted {
            guard let found = letters[position...].firstIndex(of: character) else { return nil }
            // Starting a word, or following on from the last letter, counts most.
            if found == 0 || !letters[found - 1].isLetter && !letters[found - 1].isNumber { score += 8 }
            if let previous, found == previous + 1 { score += 5 }
            score += 1
            previous = found
            position = found + 1
        }
        // The whole name typed, or its start, is best of all.
        if name.lowercased().hasPrefix(String(wanted)) { score += 20 }
        // Shorter names, where the match is more of the name, a little better.
        return score * 100 - letters.count
    }

    /// Names best first, leaving out those that don't match.
    public static func rank<T>(_ candidates: [T], query: String, name: (T) -> String, limit: Int = 30) -> [T] {
        candidates.compactMap { candidate in score(query, name(candidate)).map { (candidate, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

// MARK: - Search suggestions

/// What the search field offers as you type: the filters the last word
/// could become (#tags, in:Category, list:, kind:, is:, your fields).
public enum SearchSuggestions {
    public enum Kind: Equatable {
        case tag, category, list, kind, flag, field, filter
    }

    public struct Suggestion: Equatable {
        public var title: String
        /// The whole search text with the suggestion taken.
        public var completion: String
        public var kind: Kind
    }

    static let kinds = ["note", "link", "document", "pdf", "image", "video", "audio", "email"]
    static let flags = ["favorite", "unread", "inbox", "untagged", "uncategorized", "due", "reminder", "readlater",
                        "checklist", "highlighted"]

    public static func suggestions(for text: String, tags: [String], categories: [String], lists: [String],
                                   fields: [String], limit: Int = 8) -> [Suggestion] {
        let lastWordStart = text.lastIndex(of: " ").map { text.index(after: $0) } ?? text.startIndex
        let word = String(text[lastWordStart...])
        let before = String(text[..<lastWordStart])
        guard !word.isEmpty, !text.hasSuffix(" ") else { return [] }
        let lowered = word.lowercased()
        var result: [Suggestion] = []
        func add(_ title: String, _ token: String, _ kind: Kind) {
            guard result.count < limit, token.lowercased() != lowered else { return }
            result.append(Suggestion(title: title, completion: before + token + " ", kind: kind))
        }
        func quoted(_ name: String) -> String { name.contains(" ") ? "\"\(name)\"" : name }

        if lowered.hasPrefix("#") {
            let typed = lowered.dropFirst()
            for tag in tags where typed.isEmpty || tag.lowercased().hasPrefix(typed) { add("#" + tag, "#" + tag, .tag) }
            return result
        }
        let (prefix, rest): (String, Substring) = {
            guard let colon = lowered.firstIndex(of: ":") else { return ("", lowered[...]) }
            return (String(lowered[..<colon]), lowered[lowered.index(after: colon)...])
        }()
        switch prefix {
        case "in":
            for name in categories where rest.isEmpty || name.lowercased().hasPrefix(rest) { add(name, "in:" + quoted(name), .category) }
        case "list":
            for name in lists where rest.isEmpty || name.lowercased().hasPrefix(rest) { add(name, "list:" + quoted(name), .list) }
        case "kind":
            for name in kinds where name.hasPrefix(rest) { add(name, "kind:" + name, .kind) }
        case "is":
            for name in flags where name.hasPrefix(rest) { add(name, "is:" + name, .flag) }
        case "size":
            for example in [">1mb", ">10mb", "<100kb"] where example.hasPrefix(rest) { add("size:" + example, "size:" + example, .filter) }
        case "created", "modified":
            for example in ["today", ">7d", ">1m", "<1y"] where example.hasPrefix(rest) {
                add(prefix + ":" + example, prefix + ":" + example, .filter)
            }
        case "":
            // A plain word: tags, categories and lists it starts the name of.
            for tag in tags where tag.lowercased().hasPrefix(lowered) { add("#" + tag, "#" + tag, .tag) }
            for name in categories where name.lowercased().hasPrefix(lowered) { add("in:" + name, "in:" + quoted(name), .category) }
            for name in lists where name.lowercased().hasPrefix(lowered) { add("list:" + name, "list:" + quoted(name), .list) }
            for name in fields where name.lowercased().hasPrefix(lowered) {
                add(name + ":", name.replacingOccurrences(of: " ", with: "_") + ":", .field)
            }
            for key in ["size", "created", "modified", "source"] where lowered.count >= 2 && key.hasPrefix(lowered) {
                add(key + ":", key + ":", .filter)
            }
        default:
            break
        }
        return result
    }
}

// MARK: - Tables, lists and pictures

extension MarkdownTable {
    public enum Change {
        case addRowBelow, deleteRow, addColumnAfter, deleteColumn
    }

    /// The table around `line` changed; `column` is the cursor's column,
    /// for column changes. Nil when `line` isn't in a table, or the change
    /// would leave no table (deleting the header or the separator).
    public static func change(_ text: String, line: Int, column: Int, _ change: Change) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), isRow(lines[line].trimmingCharacters(in: .whitespaces)) else { return nil }
        var start = line, end = line + 1
        while start > 0, isRow(lines[start - 1].trimmingCharacters(in: .whitespaces)) { start -= 1 }
        while end < lines.count, isRow(lines[end].trimmingCharacters(in: .whitespaces)) { end += 1 }
        var rows = lines[start..<end].map { cells($0.trimmingCharacters(in: .whitespaces)) }
        let columns = rows.map(\.count).max() ?? 0
        let separator = rows.firstIndex { row in !row.isEmpty && row.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } } }
        let row = line - start
        let target = min(max(column, 0), max(columns - 1, 0))
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        switch change {
        case .addRowBelow:
            // Below the header means below the separator.
            let at = row == 0 && separator == 1 ? 2 : row + 1
            rows.insert(Array(repeating: "", count: columns), at: min(at, rows.count))
        case .deleteRow:
            guard row != 0, row != separator else { return nil }
            rows.remove(at: row)
        case .addColumnAfter:
            for index in rows.indices { rows[index].insert(index == separator ? "---" : "", at: target + 1) }
        case .deleteColumn:
            guard columns > 1 else { return nil }
            for index in rows.indices { rows[index].remove(at: target) }
        }
        let rebuilt = rows.map { "| " + $0.joined(separator: " | ") + " |" }
        lines.replaceSubrange(start..<end, with: rebuilt)
        let joined = lines.joined(separator: "\n")
        return tidy(joined, aroundLine: start)?.text ?? joined
    }

    /// Which cell of its row a position in a line is in.
    public static func column(at offset: Int, in line: String) -> Int {
        max(0, line.prefix(offset).filter { $0 == "|" }.count - 1)
    }
}

extension MarkdownFormatting {
    /// Moves list lines in (two spaces) or out: for nesting checklists and
    /// lists. Lines that aren't list items are left alone.
    public static func indent(_ text: String, selection: Range<Int>, outward: Bool) -> Result {
        var lines = text.components(separatedBy: "\n")
        var offset = 0
        var firstChange = 0
        var totalChange = 0
        let lower = selection.lowerBound, upper = max(selection.upperBound, selection.lowerBound)
        for index in lines.indices {
            let start = offset
            let end = start + lines[index].count
            offset = end + 1
            guard end >= lower, start <= upper || (start == lower && lower == upper) else { continue }
            let trimmed = lines[index].drop { $0 == " " }
            let isItem = ["- ", "* ", "+ "].contains { trimmed.hasPrefix($0) }
                || (trimmed.first?.isNumber == true && trimmed.contains(". "))
            guard isItem else { continue }
            let change: Int
            if outward {
                let spaces = min(2, lines[index].prefix { $0 == " " }.count)
                guard spaces > 0 else { continue }
                lines[index].removeFirst(spaces)
                change = -spaces
            } else {
                lines[index] = "  " + lines[index]
                change = 2
            }
            if totalChange == 0, firstChange == 0 { firstChange = change }
            totalChange += change
        }
        let newLower = max(0, lower + firstChange)
        return Result(text: lines.joined(separator: "\n"), selection: newLower..<max(newLower, upper + totalChange))
    }
}

extension MarkdownBlocks {
    /// A picture's alt text and the width it's limited to, from Obsidian's
    /// `![alt|300](...)`: nil for full width.
    public static func pictureSize(_ alt: String) -> (alt: String, width: Int?) {
        guard let bar = alt.lastIndex(of: "|"), let width = Int(alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)),
              width > 0 else { return (alt, nil) }
        return (String(alt[..<bar]), width)
    }

    /// The picture line with its width set (nil for full width).
    public static func settingPictureWidth(_ line: String, to width: Int?) -> String? {
        guard let picture = image(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        let alt = pictureSize(picture.alt).alt
        return "![" + alt + (width.map { "|\($0)" } ?? "") + "](" + picture.source + ")"
    }
}

// MARK: - Bookmarks files

/// A browser's exported bookmarks (Safari, Chrome, Firefox: the "Netscape"
/// HTML format), with their folders, dates and tags.
public enum BookmarksFile {
    public struct Bookmark: Equatable {
        public var title: String
        public var url: URL
        /// When it was bookmarked, from ADD_DATE.
        public var added: Date?
        /// The folders it's in, outermost first.
        public var folders: [String]
        public var tags: [String]
        /// A note or excerpt saved with it (read-later exports).
        public var note: String = ""
    }

    public static func parse(_ html: String) -> [Bookmark] {
        var bookmarks: [Bookmark] = []
        var folders: [String] = []
        var pendingFolder: String?
        let tagPattern = try! NSRegularExpression(pattern: #"<(/?)(dl|h3|a)\b([^>]*)>(?:([^<]*)</(?:h3|a)>)?"#, options: [.caseInsensitive])
        let string = html as NSString
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: string.length)) {
            let closing = string.substring(with: match.range(at: 1)) == "/"
            let name = string.substring(with: match.range(at: 2)).lowercased()
            let attributes = HTMLText.attributes(of: "<x " + string.substring(with: match.range(at: 3)) + ">")
            let inner = match.range(at: 4).location == NSNotFound ? "" : HTMLText.decodeEntities(string.substring(with: match.range(at: 4)))
            switch (name, closing) {
            case ("h3", false):
                pendingFolder = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("dl", false):
                if let pendingFolder { folders.append(pendingFolder) }
                pendingFolder = nil
            case ("dl", true):
                if !folders.isEmpty { folders.removeLast() }
            case ("a", false):
                guard let href = attributes["href"], let url = URL(string: href),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                // Pocket's HTML export says time_added.
                let added = (attributes["add_date"] ?? attributes["time_added"]).flatMap(Double.init).map { seconds in
                    // Chrome and Firefox write microseconds; Safari seconds.
                    Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000_000 : seconds)
                }
                let tags = (attributes["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let title = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                bookmarks.append(Bookmark(title: title.isEmpty ? (url.host ?? href) : title, url: url, added: added,
                                          folders: folders, tags: tags))
            default:
                break
            }
        }
        return bookmarks
    }
}
