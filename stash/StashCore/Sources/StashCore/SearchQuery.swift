import Foundation

/// What someone types in the search field, or what a smart filter keeps.
///
/// - `budget report` -- items containing words starting with both
/// - `"budget report"` -- that exact phrase
/// - `budget OR forecast` -- either word (binds tighter than the spaces
///   between words, so `2026 budget OR forecast` needs 2026 and one of the others)
/// - `-draft`, `-"old version"` -- leave out items with that word or phrase
/// - `#work`, `-#work` -- only items tagged "work", or only items without it
/// - `kind:pdf` -- note, link, document, pdf, image, video or audio
/// - `in:Work`, `in:"Work Stuff"` -- in that category or one inside it
/// - `is:favorite`, `is:unread`, `is:read`, `is:inbox`, `is:untagged`, `is:uncategorized`,
///   `is:due` (a reminder that has come round), `is:reminder` (any reminder)
/// - `label:red` (or any label colour, or `label:none`); `rating:3` -- three stars or more
/// - `after:2026-03-01`, `before:2026-03-01` -- last changed from that day on,
///   or before it; also `today`, `yesterday`, and `7d`, `2w`, `3m`, `1y` ago
/// - `created:2026-03-01` (that day), `created:>7d` (on or after), `created:<2026-01-01`
///   (before); `modified:` the same for the last change
/// - `size:>1mb`, `size:<500kb` -- a document's file, or a note's text
/// - `source:example.com` -- where a link or feed post came from
public struct SearchQuery: Equatable {
    public enum Term: Equatable {
        case word(String)
        case phrase(String)

        public var text: String {
            switch self {
            case .word(let text), .phrase(let text): text
            }
        }
    }

    public enum Kind: String, Equatable, CaseIterable {
        case note, link, document, pdf, image, video, audio, email

        init?(typed: String) {
            switch typed.lowercased() {
            case "note", "notes": self = .note
            case "link", "links", "web", "page", "pages": self = .link
            case "document", "documents", "doc", "docs", "file", "files": self = .document
            case "pdf", "pdfs": self = .pdf
            case "image", "images", "photo", "photos", "picture", "pictures": self = .image
            case "video", "videos", "movie", "movies": self = .video
            case "audio", "sound", "sounds", "music": self = .audio
            case "email", "emails", "mail", "message", "messages": self = .email
            default: return nil
            }
        }
    }

    public enum Flag: String, Equatable {
        case favorite, unread, read, inbox, untagged, uncategorized, due, reminder, readLater, checklist, highlighted

        init?(typed: String) {
            switch typed.lowercased() {
            case "favorite", "favorites", "favourite", "favourites", "starred", "flagged": self = .favorite
            case "unread", "new": self = .unread
            case "read": self = .read
            case "inbox", "unfiled": self = .inbox
            case "due", "overdue": self = .due
            case "reminder", "reminders", "remind": self = .reminder
            case "untagged": self = .untagged
            case "uncategorized", "uncategorised": self = .uncategorized
            case "readlater", "later", "queue", "queued": self = .readLater
            case "checklist", "checklists", "todo", "todos", "task", "tasks": self = .checklist
            case "highlighted", "highlights", "highlight": self = .highlighted
            default: return nil
            }
        }
    }

    /// A day typed after `before:` or `after:`.
    public enum Day: Equatable {
        case date(year: Int, month: Int, day: Int)
        /// So many days, weeks, months or years before today.
        case ago(Int, Calendar.Component)

        init?(typed: String) {
            let text = typed.lowercased()
            switch text {
            case "today": self = .ago(0, .day)
            case "yesterday": self = .ago(1, .day)
            default:
                let parts = text.split(separator: "-")
                if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                   parts[0].count == 4, (1...12).contains(month), (1...31).contains(day) {
                    self = .date(year: year, month: month, day: day)
                    return
                }
                guard let unit = text.last, let count = Int(text.dropLast()), count >= 0 else { return nil }
                switch unit {
                case "d": self = .ago(count, .day)
                case "w": self = .ago(count * 7, .day)
                case "m": self = .ago(count, .month)
                case "y": self = .ago(count, .year)
                default: return nil
                }
            }
        }

        /// The start of that day.
        public func start(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .date(let year, let month, let day):
                return calendar.date(from: DateComponents(year: year, month: month, day: day))
            case .ago(let count, let unit):
                let today = calendar.startOfDay(for: now)
                return calendar.date(byAdding: unit, value: -count, to: today)
            }
        }
    }

    /// How a size or a date is compared with what's typed.
    public enum Comparison: Equatable {
        case less, lessOrEqual, equal, greaterOrEqual, greater

        /// Takes `>`, `>=`, `<`, `<=` or `=` off the front of `text`.
        static func split(_ text: String) -> (Comparison?, String) {
            for (prefix, comparison) in [(">=", Comparison.greaterOrEqual), ("<=", .lessOrEqual), (">", .greater),
                                         ("<", .less), ("=", .equal)] where text.hasPrefix(prefix) {
                return (comparison, String(text.dropFirst(prefix.count)))
            }
            return (nil, text)
        }
    }

    public struct SizeFilter: Equatable {
        public var comparison: Comparison
        public var bytes: Int64

        /// `1mb`, `1.5 GB`, `500k`, `200` (bytes); a thousand to the kilobyte, as the Finder counts.
        init?(typed: String) {
            let (comparison, rest) = Comparison.split(typed.lowercased().replacingOccurrences(of: " ", with: ""))
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard let value = Double(number), value >= 0 else { return nil }
            let multiplier: Double
            switch rest.dropFirst(number.count) {
            case "", "b", "byte", "bytes": multiplier = 1
            case "k", "kb": multiplier = 1e3
            case "m", "mb": multiplier = 1e6
            case "g", "gb": multiplier = 1e9
            default: return nil
            }
            self.comparison = comparison ?? .greaterOrEqual
            bytes = Int64(value * multiplier)
        }

        public func matches(_ size: Int64) -> Bool {
            switch comparison {
            case .less: size < bytes
            case .lessOrEqual: size <= bytes
            case .equal: size == bytes
            case .greaterOrEqual: size >= bytes
            case .greater: size > bytes
            }
        }
    }

    public struct DateFilter: Equatable {
        public var comparison: Comparison
        public var day: Day

        init?(typed: String) {
            let (comparison, rest) = Comparison.split(typed)
            guard let day = Day(typed: rest) else { return nil }
            self.comparison = comparison ?? .equal
            self.day = day
        }

        /// On that day; on or after it (`>` and `>=`); before it (`<`); on or before it (`<=`).
        public func matches(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
            guard let start = day.start(now: now, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
            switch comparison {
            case .equal: return date >= start && date < end
            case .greater, .greaterOrEqual: return date >= start
            case .less: return date < start
            case .lessOrEqual: return date < end
            }
        }
    }

    /// Words and phrases every result has: one from each group.
    public private(set) var groups: [[Term]] = []
    /// Words and phrases no result has.
    public private(set) var excludedTerms: [Term] = []
    /// Tag keys (see `TagName.key`).
    public private(set) var tags: [String] = []
    public private(set) var excludedTags: [String] = []
    /// Any one of these.
    public private(set) var kinds: [Kind] = []
    /// Category names, lowercased; any one of these, or a category inside one.
    public private(set) var categories: [String] = []
    public private(set) var flags: [Flag] = []
    /// Any one of these; `.none` for items without a label.
    public private(set) var labels: [ItemLabel] = []
    /// Only items rated this many stars or more.
    public private(set) var minimumRating: Int?
    public private(set) var after: Day?
    public private(set) var before: Day?
    /// List names, lowercased; items in any one of these.
    public private(set) var lists: [String] = []
    /// All of these.
    public private(set) var sizes: [SizeFilter] = []
    public private(set) var created: [DateFilter] = []
    public private(set) var modified: [DateFilter] = []
    /// Lowercased; where it came from contains any one of these.
    public private(set) var sources: [String] = []
    public struct FieldFilter: Equatable {
        /// The field's name, as defined.
        public var name: String
        /// What it must match: words, or `>`, `<`, `>=`, `<=` and a number or date.
        public var value: String
    }

    /// Custom fields, and what each must match.
    public private(set) var fieldFilters: [FieldFilter] = []
    /// The custom fields there are, by lowercased name, so `Name:value`
    /// can tell a field from a word with a colon in it.
    private var fieldNames: [String: String] = [:]

    /// Every word and phrase that's searched for, in order.
    public var terms: [Term] { groups.flatMap { $0 } }

    private struct Token {
        /// "-", or a filter such as "in:", written before a quoted phrase.
        var prefix = ""
        var text: String
        var quoted: Bool
    }

    private static let filterKeys: Set<String> = ["kind", "type", "in", "is", "after", "before", "label", "rating", "list",
                                                         "size", "created", "added", "modified", "changed", "source", "site"]

    /// `fields`: the names of the custom fields there are.
    public init(_ text: String, fields: [String] = []) {
        for name in fields {
            fieldNames[Self.fieldKey(name)] = name
        }
        var orPending = false
        let names = fieldNames
        for token in Self.tokens(in: text, isFilter: { names[Self.fieldKey($0)] != nil }) {
            var value = token.text
            var negated = false
            if token.quoted {
                negated = token.prefix == "-"
                if token.prefix.hasSuffix(":"), applyFilter(String(token.prefix.dropLast()), value) {
                    orPending = false
                    continue
                }
            } else {
                if value == "OR" {
                    orPending = !groups.isEmpty
                    continue
                }
                if value.hasPrefix("-"), value.count > 1 {
                    negated = true
                    value.removeFirst()
                }
                if value.hasPrefix("#"), value.count > 1 {
                    let key = TagName.key(value)
                    if !key.isEmpty {
                        if negated {
                            if !excludedTags.contains(key) { excludedTags.append(key) }
                        } else if !tags.contains(key) {
                            tags.append(key)
                        }
                    }
                    orPending = false
                    continue
                }
                if !negated, let colon = value.firstIndex(of: ":"),
                   applyFilter(String(value[..<colon]), String(value[value.index(after: colon)...])) {
                    orPending = false
                    continue
                }
            }

            let term: Term = token.quoted ? .phrase(value) : .word(value)
            if token.quoted, value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if negated {
                excludedTerms.append(term)
            } else if orPending {
                groups[groups.count - 1].append(term)
            } else {
                groups.append([term])
            }
            orPending = false
        }
    }

    /// Splits the text at spaces outside quotes. A quote also ends the word
    /// before it, unless that word is `-` or a filter like `in:`, which then
    /// applies to the quoted phrase.
    private static func tokens(in text: String, isFilter: (String) -> Bool) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var prefix = ""
        var inPhrase = false

        for character in text {
            if character == "\"" {
                if inPhrase {
                    tokens.append(Token(prefix: prefix, text: current, quoted: true))
                    prefix = ""
                } else {
                    if isPhrasePrefix(current, isFilter: isFilter) {
                        prefix = current
                    } else if !current.isEmpty {
                        tokens.append(Token(text: current, quoted: false))
                    }
                }
                current = ""
                inPhrase.toggle()
            } else if character.isWhitespace && !inPhrase {
                if !current.isEmpty { tokens.append(Token(text: current, quoted: false)) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if inPhrase {
            tokens.append(Token(prefix: prefix, text: current, quoted: true))
        } else if !current.isEmpty {
            tokens.append(Token(text: current, quoted: false))
        }
        return tokens
    }

    private static func isPhrasePrefix(_ text: String, isFilter: (String) -> Bool) -> Bool {
        if text == "-" { return true }
        guard text.hasSuffix(":") else { return false }
        let key = String(text.dropLast())
        return filterKeys.contains(key.lowercased()) || isFilter(key)
    }

    /// A field's name as typed: case doesn't matter, and `_` stands for a space.
    static func fieldKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Whether `key:value` is a filter; if so, it's added.
    private mutating func applyFilter(_ key: String, _ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        switch key.lowercased() {
        case "kind", "type":
            guard let kind = Kind(typed: value) else { return false }
            if !kinds.contains(kind) { kinds.append(kind) }
        case "in":
            let name = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return false }
            if !categories.contains(name) { categories.append(name) }
        case "is":
            guard let flag = Flag(typed: value) else { return false }
            if !flags.contains(flag) { flags.append(flag) }
        case "label":
            guard let label = ItemLabel(typed: value) else { return false }
            if !labels.contains(label) { labels.append(label) }
        case "rating", "stars":
            let digits = value.drop { $0 == ">" || $0 == "=" }
            guard let stars = Int(digits), (0...5).contains(stars) else { return false }
            minimumRating = stars
        case "after":
            guard let day = Day(typed: value) else { return false }
            after = day
        case "before":
            guard let day = Day(typed: value) else { return false }
            before = day
        case "list":
            let name = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return false }
            if !lists.contains(name) { lists.append(name) }
        case "size":
            guard let size = SizeFilter(typed: value) else { return false }
            sizes.append(size)
        case "created", "added":
            guard let date = DateFilter(typed: value) else { return false }
            created.append(date)
        case "modified", "changed":
            guard let date = DateFilter(typed: value) else { return false }
            modified.append(date)
        case "source", "site":
            let text = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !text.isEmpty else { return false }
            if !sources.contains(text) { sources.append(text) }
        default:
            guard let name = fieldNames[Self.fieldKey(key)] else { return false }
            fieldFilters.append(FieldFilter(name: name, value: value.trimmingCharacters(in: .whitespaces)))
        }
        return true
    }

    public var isEmpty: Bool {
        groups.isEmpty && excludedTerms.isEmpty && tags.isEmpty && excludedTags.isEmpty
            && kinds.isEmpty && categories.isEmpty && flags.isEmpty && after == nil && before == nil
            && labels.isEmpty && minimumRating == nil && lists.isEmpty && fieldFilters.isEmpty
            && sizes.isEmpty && created.isEmpty && modified.isEmpty && sources.isEmpty
    }

    /// An SQLite FTS5 `MATCH` expression for the words and phrases, or nil
    /// when there are none. Every term is quoted, so nothing typed can be
    /// read as FTS syntax; words also match as prefixes, so results appear
    /// while a word is still being typed.
    public var ftsExpression: String? {
        let parts: [String] = groups.compactMap { group in
            let alternatives = group.compactMap(Self.expression)
            switch alternatives.count {
            case 0: return nil
            case 1: return alternatives[0]
            default: return "(" + alternatives.joined(separator: " OR ") + ")"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// An FTS5 expression matching any of the left-out words and phrases,
    /// or nil when there are none. Results matching it are dropped.
    public var excludedExpression: String? {
        let parts = excludedTerms.compactMap(Self.expression)
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }

    private static func expression(for term: Term) -> String? {
        switch term {
        case .word(let word):
            return isSearchable(word) ? quoted(word) + "*" : nil
        case .phrase(let phrase):
            return isSearchable(phrase) ? quoted(phrase) : nil
        }
    }

    /// An FTS5 expression matching `text` as a phrase within one column.
    public static func phrase(_ text: String, inColumn column: String) -> String? {
        isSearchable(text) ? "\(column) : \(quoted(text))" : nil
    }

    /// An FTS5 expression matching any of `words` exactly (no prefixes).
    public static func anyWord(_ words: [String]) -> String? {
        let parts = words.filter(isSearchable).map(quoted)
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// FTS5 rejects a quoted string with no words in it, such as `"-"`.
    static func isSearchable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
