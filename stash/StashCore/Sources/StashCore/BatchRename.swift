import Foundation

/// Renaming many items at once, as DEVONthink's batch rename: find and
/// replace in their titles, add text before or after, or give each a new
/// title from a pattern.
public enum BatchRename {
    public enum Mode: Equatable {
        /// Every match of `find` becomes `replace`; with `regex`, `find` is
        /// a regular expression and `$1` in `replace` is its first group.
        case replace(find: String, replace: String, ignoringCase: Bool, regex: Bool)
        case add(prefix: String, suffix: String)
        /// A new title from a pattern: `{title}` the old title, `{n}` a
        /// counter (from `start`, with `digits` digits at least), `{date}`
        /// the date made (`{date:yyyy-MM-dd}` in any format), `{kind}`.
        case pattern(String, start: Int, digits: Int)
    }

    public struct Source: Equatable {
        public var title: String
        public var created: Date
        public var kind: String

        public init(title: String, created: Date, kind: String) {
            self.title = title
            self.created = created
            self.kind = kind
        }
    }

    /// The new titles, in the same order. A title that would come out
    /// empty is left as it was.
    public static func titles(for sources: [Source], mode: Mode, calendar: Calendar = .current,
                              locale: Locale = .current) -> [String] {
        sources.enumerated().map { position, source in
            let renamed = title(for: source, at: position, mode: mode, calendar: calendar, locale: locale)
            let trimmed = renamed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? source.title : trimmed
        }
    }

    private static func title(for source: Source, at position: Int, mode: Mode, calendar: Calendar, locale: Locale) -> String {
        switch mode {
        case .replace(let find, let replace, let ignoringCase, let regex):
            guard !find.isEmpty else { return source.title }
            if regex {
                guard let expression = try? NSRegularExpression(pattern: find, options: ignoringCase ? [.caseInsensitive] : []) else {
                    return source.title
                }
                let range = NSRange(location: 0, length: (source.title as NSString).length)
                return expression.stringByReplacingMatches(in: source.title, range: range, withTemplate: replace)
            }
            return source.title.replacingOccurrences(of: find, with: replace, options: ignoringCase ? [.caseInsensitive] : [])
        case .add(let prefix, let suffix):
            return prefix + source.title + suffix
        case .pattern(let pattern, let start, let digits):
            var values = NoteTemplate.Values(date: source.created, title: source.title, calendar: calendar, locale: locale)
            values.title = source.title
            var text = pattern
            let number = String(start + position)
            let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
            text = text.replacingOccurrences(of: "{n}", with: padded, options: .caseInsensitive)
            text = text.replacingOccurrences(of: "{kind}", with: source.kind, options: .caseInsensitive)
            // Single braces, as typed here; the template filler wants double.
            text = text.replacingOccurrences(of: "{title}", with: "{{title}}", options: .caseInsensitive)
            let datePattern = try! NSRegularExpression(pattern: #"\{date(:[^{}]*)?\}"#, options: .caseInsensitive)
            text = datePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                         withTemplate: "{{date$1}}")
            return NoteTemplate.fill(text, with: values)
        }
    }
}

extension MarkdownStyling {
    /// The note's text without the Markdown, keeping its lines: for a
    /// plain-text copy.
    public static func plainLines(_ text: String) -> String {
        let string = text as NSString
        var hidden = IndexSet()
        for span in spans(in: text) {
            switch span.style {
            case .marker, .image: hidden.insert(integersIn: span.range)
            default: break
            }
        }
        var units: [unichar] = []
        units.reserveCapacity(string.length)
        for index in 0..<string.length where !hidden.contains(index) {
            units.append(string.character(at: index))
        }
        // Pictures leave empty lines; more than one blank line in a row goes.
        var lines: [String] = []
        for line in String(utf16CodeUnits: units, count: units.count).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
