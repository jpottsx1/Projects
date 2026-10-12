import Foundation

/// Where the Markdown is in a note, for showing it formatted as it's typed
/// (as Typora does): headings large, bold bold, and the marks themselves --
/// `**`, `#`, `[[` -- tucked away except on the line being edited.
///
/// Offsets are UTF-16, the way `NSString` and the system text views count.
public enum MarkdownStyling {
    public enum Style: Equatable {
        /// The text of a heading line, at this level.
        case heading(Int)
        /// Syntax to hide away from the line being edited: `**`, `# `, `](url)`.
        case marker
        case bold, italic, strikethrough
        case code
        /// A line inside a ``` fence.
        case codeBlock
        /// The text of a `[label](url)` link.
        case link
        /// The title (or label) of a `[[link]]`.
        case wikiLink
        /// The text of a `>` quote line.
        case quote
        /// `- `, `1. `: shown, but quieter than the text.
        case listMarker
        /// `[ ]` or `[x]` in a task line.
        case task(done: Bool)
        /// A `---` line.
        case rule
        /// A picture's whole `![alt](source)` line, and where it comes from.
        case image(source: String)
        /// A line of a table, shown in fixed-width type so its columns line up.
        case tableRow
    }

    public struct Span: Equatable {
        public var range: Range<Int>
        public var style: Style

        public init(_ range: Range<Int>, _ style: Style) {
            self.range = range
            self.style = style
        }
    }

    public static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var inFence = false
        var lineStart = 0
        while lineStart < max(string.length, 1) {
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location,
                  [0x0A, 0x0D].contains(string.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let line = string.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
            let start = lineRange.location
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                spans.append(Span(start..<contentEnd, .marker))
            } else if inFence {
                if contentEnd > start { spans.append(Span(start..<contentEnd, .codeBlock)) }
            } else {
                spans += lineSpans(line, at: start)
            }

            // Asked for at the very end, the last line comes back again.
            let next = lineRange.location + lineRange.length
            if next >= string.length || lineRange.length == 0 { break }
            lineStart = next
        }
        return spans
    }

    /// The spans of one line outside a code fence.
    static func lineSpans(_ line: String, at start: Int) -> [Span] {
        let units = (line as NSString).length
        guard units > 0 else { return [] }
        var spans: [Span] = []
        var contentStart = 0
        let leading = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let body = String(line.dropFirst(line.prefix { $0 == " " || $0 == "\t" }.count))

        if let picture = MarkdownBlocks.image(body.trimmingCharacters(in: .whitespaces)) {
            return [Span(start..<(start + units), .image(source: picture.source))]
        } else if MarkdownTable.isRow(body.trimmingCharacters(in: .whitespaces)) {
            return [Span(start..<(start + units), .tableRow)]
        } else if let (level, _) = MarkdownBlocks.heading(body) {
            let marks = leading + level + (body.dropFirst(level).first == " " ? 1 : 0)
            spans.append(Span(start..<(start + marks), .marker))
            if marks < units { spans.append(Span((start + marks)..<(start + units), .heading(level))) }
            contentStart = marks
        } else if MarkdownBlocks.isRule(body) {
            return [Span(start..<(start + units), .rule)]
        } else if body.hasPrefix(">") {
            let marks = leading + 1 + (body.dropFirst().first == " " ? 1 : 0)
            spans.append(Span(start..<(start + marks), .marker))
            if marks < units { spans.append(Span((start + marks)..<(start + units), .quote)) }
            contentStart = marks
        } else if MarkdownBlocks.bullet(body) != nil {
            let marks = leading + 2
            spans.append(Span(start..<(start + marks), .listMarker))
            contentStart = marks
            let rest = body.dropFirst(2)
            if rest.hasPrefix("[ ]") || rest.hasPrefix("[x]") || rest.hasPrefix("[X]") {
                spans.append(Span((start + marks)..<(start + marks + 3), .task(done: !rest.hasPrefix("[ ]"))))
                contentStart = marks + 3
            }
        } else if let digits = Optional(body.prefix { $0.isASCII && $0.isNumber }), !digits.isEmpty,
                  body.dropFirst(digits.count).hasPrefix(". ") || body.dropFirst(digits.count).hasPrefix(") ") {
            let marks = leading + digits.count + 2
            spans.append(Span(start..<(start + marks), .listMarker))
            contentStart = marks
        }

        spans += inlineSpans(line, from: contentStart, at: start)
        return spans
    }

    private static let codePattern = try! NSRegularExpression(pattern: "(`+)(.+?)\\1")
    private static let wikiPattern = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n|]+)(\\|([^\\[\\]\\n]+))?\\]\\]")
    private static let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\[\\]\\n]+)\\]\\(([^()\\s]+)\\)")
    private static let boldPattern = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strikePattern = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)~~")
    private static let italicPattern = try! NSRegularExpression(
        pattern: "(?<![\\*\\w])(\\*|_)(?=[^\\s\\*_])(.+?)(?<=[^\\s\\*_])\\1(?![\\*\\w])")

    /// Bold, italics, code and links within a line, after `from`.
    static func inlineSpans(_ line: String, from: Int, at start: Int) -> [Span] {
        let string = line as NSString
        guard from < string.length else { return [] }
        let searched = NSRange(location: from, length: string.length - from)
        var spans: [Span] = []
        /// Stretches already claimed, so a `*` inside code isn't italics.
        var taken: [NSRange] = []
        func isFree(_ range: NSRange) -> Bool {
            !taken.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func add(_ range: NSRange, _ style: Style) {
            guard range.length > 0 else { return }
            spans.append(Span((start + range.location)..<(start + range.location + range.length), style))
        }

        for match in codePattern.matches(in: line, range: searched) where isFree(match.range) {
            let fence = match.range(at: 1).length
            add(NSRange(location: match.range.location, length: fence), .marker)
            add(match.range(at: 2), .code)
            add(NSRange(location: match.range.location + match.range.length - fence, length: fence), .marker)
            taken.append(match.range)
        }
        for match in wikiPattern.matches(in: line, range: searched) where isFree(match.range) {
            let whole = match.range
            add(NSRange(location: whole.location, length: 2), .marker)
            if match.range(at: 3).location != NSNotFound {
                // [[Title|label]]: the title and bar are tucked away, the label shown.
                add(NSRange(location: whole.location + 2, length: match.range(at: 1).length + 1), .marker)
                add(match.range(at: 3), .wikiLink)
            } else {
                add(match.range(at: 1), .wikiLink)
            }
            add(NSRange(location: whole.location + whole.length - 2, length: 2), .marker)
            taken.append(whole)
        }
        for match in linkPattern.matches(in: line, range: searched) where isFree(match.range) {
            let whole = match.range, label = match.range(at: 1)
            add(NSRange(location: whole.location, length: 1), .marker)
            add(label, .link)
            add(NSRange(location: label.location + label.length, length: whole.location + whole.length - label.location - label.length), .marker)
            taken.append(whole)
        }
        for (pattern, style) in [(boldPattern, Style.bold), (strikePattern, .strikethrough), (italicPattern, .italic)] {
            for match in pattern.matches(in: line, range: searched) where isFree(match.range) {
                let mark = match.range(at: 1).length
                add(NSRange(location: match.range.location, length: mark), .marker)
                add(match.range(at: 2), style)
                add(NSRange(location: match.range.location + match.range.length - mark, length: mark), .marker)
                taken.append(match.range)
            }
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The UTF-16 range of each line the selection touches, so its marks can be shown.
    public static func lines(touching selection: Range<Int>, in text: String) -> Range<Int> {
        let string = text as NSString
        let lower = min(selection.lowerBound, string.length), upper = min(max(selection.upperBound, lower), string.length)
        let range = string.lineRange(for: NSRange(location: lower, length: upper - lower))
        return range.location..<(range.location + range.length)
    }

    /// The note's words without the Markdown: for a line under its title in
    /// a list, a widget or Spotlight. Lines are joined with spaces.
    public static func plainText(_ text: String) -> String {
        let string = text as NSString
        var hidden = IndexSet()
        for span in spans(in: text) {
            switch span.style {
            case .marker, .listMarker, .task, .rule, .image: hidden.insert(integersIn: span.range)
            default: break
            }
        }
        var units: [unichar] = []
        units.reserveCapacity(string.length)
        for index in 0..<string.length where !hidden.contains(index) {
            units.append(string.character(at: index))
        }
        return String(utf16CodeUnits: units, count: units.count)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
