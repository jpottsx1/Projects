import Foundation

/// HTML as Markdown, for notes coming in from elsewhere: Evernote's ENML,
/// exported HTML pages, notes saved by other apps. Headings, emphasis,
/// links, lists (nested, numbered, to-do), quotes, code, rules and tables
/// come through; styling and layout don't.
///
/// Pictures are up to the caller, who knows where they are: `picture` is
/// asked about each `<img>` (and Evernote's `<en-media>`) and returns the
/// Markdown to put in its place, or nil to drop it.
public enum HTMLMarkdown {
    public struct Picture {
        /// `<img>` or `<en-media>`.
        public var tag: String
        public var attributes: [String: String]
    }

    public static func convert(_ html: String, picture: (Picture) -> String? = defaultPicture) -> String {
        withoutActuallyEscaping(picture) { picture in
            var writer = Writer(picture: picture)
            for token in Tokenizer.tokens(html) { writer.handle(token) }
            return writer.finish()
        }
    }

    /// Pictures on the web stay where they are; others are dropped.
    public static func defaultPicture(_ picture: Picture) -> String? {
        guard picture.tag == "img", let source = picture.attributes["src"],
              source.hasPrefix("http://") || source.hasPrefix("https://") else { return nil }
        return "![\(picture.attributes["alt"] ?? "")](\(source))"
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case open(String, [String: String], selfClosing: Bool)
        case close(String)
        case text(String)
    }

    enum Tokenizer {
        /// Elements whose contents are never shown.
        static let hidden: Set<String> = ["script", "style", "head", "title", "template", "noscript", "svg", "en-crypt"]

        static func tokens(_ html: String) -> [Token] {
            var tokens: [Token] = []
            let scalars = Array(html.unicodeScalars)
            var index = 0
            var text = String.UnicodeScalarView()
            func flushText() {
                if !text.isEmpty { tokens.append(.text(String(text))) }
                text = String.UnicodeScalarView()
            }
            func starts(_ prefix: String, at position: Int) -> Bool {
                let wanted = Array(prefix.unicodeScalars)
                guard position + wanted.count <= scalars.count else { return false }
                for offset in wanted.indices where
                    String(scalars[position + offset]).lowercased() != String(wanted[offset]).lowercased() { return false }
                return true
            }
            func find(_ string: String, from position: Int) -> Int? {
                var at = position
                while at < scalars.count {
                    if starts(string, at: at) { return at }
                    at += 1
                }
                return nil
            }

            while index < scalars.count {
                let scalar = scalars[index]
                guard scalar == "<" else {
                    text.append(scalar)
                    index += 1
                    continue
                }
                if starts("<!--", at: index) {
                    flushText()
                    index = (find("-->", from: index + 4) ?? scalars.count - 3) + 3
                    continue
                }
                if starts("<![CDATA[", at: index) {
                    let end = find("]]>", from: index + 9) ?? scalars.count
                    text.append(contentsOf: scalars[(index + 9)..<end])
                    index = end + 3
                    continue
                }
                if starts("<!", at: index) || starts("<?", at: index) {
                    flushText()
                    index = (find(">", from: index) ?? scalars.count - 1) + 1
                    continue
                }
                // A tag: up to the next > outside quotes.
                var end = index + 1
                var quote: Unicode.Scalar?
                while end < scalars.count {
                    let c = scalars[end]
                    if let open = quote {
                        if c == open { quote = nil }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == ">" {
                        break
                    }
                    end += 1
                }
                let inside = String(String.UnicodeScalarView(scalars[(index + 1)..<min(end, scalars.count)]))
                let first = inside.first
                guard let first, first.isLetter || first == "/" else {
                    // A lone "<" in text.
                    text.append(scalar)
                    index += 1
                    continue
                }
                flushText()
                index = end + 1
                if first == "/" {
                    tokens.append(.close(name(of: String(inside.dropFirst()))))
                    continue
                }
                let tagName = name(of: inside)
                let selfClosing = inside.hasSuffix("/")
                tokens.append(.open(tagName, HTMLText.attributes(of: "<" + inside + ">"), selfClosing: selfClosing))
                // Skip what hidden elements hold, to their end.
                if hidden.contains(tagName), !selfClosing {
                    let closing = "</" + tagName
                    let stop = find(closing, from: index) ?? scalars.count
                    index = (find(">", from: stop) ?? scalars.count - 1) + 1
                    tokens.append(.close(tagName))
                }
            }
            flushText()
            return tokens
        }

        private static func name(of inside: String) -> String {
            String(inside.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }).lowercased()
        }
    }

    // MARK: - Writing

    private struct Writer {
        let picture: (Picture) -> String?
        var output = ""
        var atLineStart = true
        var quoteDepth = 0
        /// Each open list: whether it's numbered, and the next number.
        var lists: [(ordered: Bool, next: Int)] = []
        /// Characters to indent continuation lines of the list item by.
        var preDepth = 0
        var hiddenDepth = 0
        /// Inline marks waiting for their first word: `**` before ` word`
        /// would come out as `** word`.
        var pendingMarks = ""
        /// For each open inline mark: whether its text has started.
        var marks: [(mark: String, started: Bool)] = []
        var links: [(start: Int, href: String)] = []
        var tableDepth = 0
        var tableRows: [[String]] = []
        var row: [String] = []
        var cellStart: Int?

        init(picture: @escaping (Picture) -> String?) {
            self.picture = picture
        }

        var prefix: String {
            String(repeating: "> ", count: quoteDepth) + String(repeating: "  ", count: max(0, lists.count - 1))
        }

        mutating func write(_ string: String) {
            guard !string.isEmpty else { return }
            if atLineStart, cellStart == nil {
                if quoteBlankLine, quoteDepth > 0 {
                    output += String(repeating: "> ", count: quoteDepth).trimmingCharacters(in: .whitespaces) + "\n"
                }
                quoteBlankLine = false
                output += prefix
                // A list item's continuation lines line up under its text.
                if !lists.isEmpty, !string.hasPrefix("- "), !(string.first?.isNumber ?? false) { output += "  " }
            }
            output += string
            atLineStart = false
            startedItem = false
        }

        mutating func newline() {
            if cellStart != nil { write(" "); return }
            // No spaces at the ends of lines.
            while output.hasSuffix(" ") { output.removeLast() }
            output += "\n"
            atLineStart = true
        }

        var quoteBlankLine = false
        /// Just after a list item's `- `, where its text belongs on the same line.
        var startedItem = false

        /// Starts a new line, unless already at the start of one.
        mutating func endLine() {
            if !atLineStart, !startedItem { newline() }
        }

        /// Leaves a blank line before what comes next.
        mutating func blankLine() {
            guard cellStart == nil else { write(" "); return }
            guard !startedItem else { return }
            endLine()
            guard !output.isEmpty, !output.hasSuffix("\n\n") else { return }
            if quoteDepth > 0 {
                // Written only if more of the quote follows.
                quoteBlankLine = true
            } else if lists.isEmpty {
                output += "\n"
            }
        }

        mutating func text(_ raw: String) {
            guard hiddenDepth == 0 else { return }
            let decoded = HTMLText.decodeEntities(raw)
            if preDepth > 0 {
                for (number, line) in decoded.components(separatedBy: "\n").enumerated() {
                    if number > 0 { output += "\n"; atLineStart = true }
                    if !line.isEmpty {
                        if atLineStart { output += prefix }
                        output += line
                        atLineStart = false
                    }
                }
                return
            }
            var collapsed = decoded.replacingOccurrences(of: "\u{00A0}", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty else {
                // Whitespace between words is still a space.
                if !decoded.isEmpty, !atLineStart, !output.hasSuffix(" ") { output += " " }
                return
            }
            if decoded.first?.isWhitespace == true, !atLineStart, !output.hasSuffix(" ") { collapsed = " " + collapsed }
            if decoded.last?.isWhitespace == true { collapsed += " " }
            if atLineStart { collapsed = String(collapsed.drop { $0 == " " }) }
            if !pendingMarks.isEmpty {
                let leading = collapsed.prefix { $0 == " " }
                write(String(leading) + pendingMarks)
                collapsed = String(collapsed.dropFirst(leading.count))
                pendingMarks = ""
                for index in marks.indices { marks[index].started = true }
            }
            write(collapsed)
        }

        mutating func openMark(_ mark: String) {
            marks.append((mark, false))
            pendingMarks += mark
        }

        mutating func closeMark(_ mark: String) {
            guard let index = marks.lastIndex(where: { $0.mark == mark }) else { return }
            let started = marks[index].started
            marks.remove(at: index)
            guard started else {
                // Nothing inside: no marks at all.
                if let range = pendingMarks.range(of: mark, options: .backwards) { pendingMarks.removeSubrange(range) }
                return
            }
            var trailing = ""
            while output.hasSuffix(" ") { output.removeLast(); trailing += " " }
            output += mark + trailing
        }

        mutating func handle(_ token: Token) {
            switch token {
            case .text(let string):
                text(string)
            case .open(let name, let attributes, let selfClosing):
                if Tokenizer.hidden.contains(name) {
                    if name == "en-crypt" { write("[Encrypted text]") }
                    if !selfClosing { hiddenDepth += 1 }
                    return
                }
                guard hiddenDepth == 0 else { return }
                open(name, attributes)
                if selfClosing { close(name) }
            case .close(let name):
                if Tokenizer.hidden.contains(name) {
                    hiddenDepth = max(0, hiddenDepth - 1)
                    return
                }
                guard hiddenDepth == 0 else { return }
                close(name)
            }
        }

        mutating func open(_ name: String, _ attributes: [String: String]) {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blankLine()
                write(String(repeating: "#", count: Int(String(name.last!)) ?? 1) + " ")
            case "p":
                blankLine()
            case "div", "section", "article", "header", "footer", "main", "figure", "figcaption", "dt", "dd":
                endLine()
            case "br":
                if preDepth > 0 { output += "\n"; atLineStart = true } else { newline() }
            case "hr":
                blankLine()
                write("---")
                blankLine()
            case "b", "strong":
                openMark("**")
            case "i", "em", "cite":
                openMark("_")
            case "s", "del", "strike":
                openMark("~~")
            case "code" where preDepth == 0:
                openMark("`")
            case "pre":
                blankLine()
                write("```")
                newline()
                preDepth += 1
            case "blockquote":
                blankLine()
                quoteDepth += 1
            case "ul", "ol":
                if lists.isEmpty { blankLine() } else { endLine() }
                let start = Int(attributes["start"] ?? "") ?? 1
                lists.append((name == "ol", start))
            case "li":
                endLine()
                guard !lists.isEmpty else { write("- "); return }
                let index = lists.count - 1
                if lists[index].ordered {
                    write("\(lists[index].next). ")
                    lists[index].next += 1
                } else {
                    write("- ")
                }
                startedItem = true
            case "en-todo":
                let done = attributes["checked"]?.lowercased() == "true"
                if atLineStart && lists.isEmpty { write("- ") }
                write(done ? "[x] " : "[ ] ")
                if !lists.isEmpty { startedItem = true }
            case "a":
                links.append((output.utf16.count, attributes["href"] ?? ""))
            case "img", "en-media":
                guard let markdown = picture(Picture(tag: name, attributes: attributes)) else { return }
                if markdown.hasPrefix("!["), cellStart == nil {
                    // A picture shows when it's on a line of its own.
                    endLine()
                    write(markdown)
                    newline()
                } else {
                    write(markdown)
                }
            case "table":
                tableDepth += 1
                if tableDepth == 1 { blankLine(); tableRows = [] }
            case "tr":
                if tableDepth == 1 { row = [] }
            case "td", "th":
                if tableDepth == 1 {
                    endLine()
                    cellStart = output.utf16.count
                }
            default:
                break
            }
        }

        mutating func close(_ name: String) {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6", "p":
                blankLine()
            case "div", "section", "article", "header", "footer", "main", "figure", "figcaption", "dt", "dd":
                endLine()
            case "b", "strong":
                closeMark("**")
            case "i", "em", "cite":
                closeMark("_")
            case "s", "del", "strike":
                closeMark("~~")
            case "code" where preDepth == 0:
                closeMark("`")
            case "pre":
                guard preDepth > 0 else { return }
                preDepth -= 1
                endLine()
                write("```")
                blankLine()
            case "blockquote":
                guard quoteDepth > 0 else { return }
                endLine()
                quoteDepth -= 1
                quoteBlankLine = false
                blankLine()
            case "ul", "ol":
                guard !lists.isEmpty else { return }
                endLine()
                lists.removeLast()
                if lists.isEmpty { blankLine() }
            case "li":
                endLine()
            case "a":
                guard let link = links.popLast() else { return }
                closeLink(link)
            case "td", "th":
                guard tableDepth == 1, let start = cellStart else { return }
                let utf16 = Array(output.utf16)
                let cell = String(decoding: utf16[start...], as: UTF16.self)
                output = String(decoding: utf16[..<start], as: UTF16.self)
                cellStart = nil
                atLineStart = output.isEmpty || output.hasSuffix("\n")
                row.append(cell.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|"))
            case "tr":
                if tableDepth == 1, !row.isEmpty { tableRows.append(row) }
                row = []
            case "table":
                guard tableDepth > 0 else { return }
                tableDepth -= 1
                if tableDepth == 0 { writeTable() }
            default:
                break
            }
        }

        mutating func closeLink(_ link: (start: Int, href: String)) {
            let utf16 = Array(output.utf16)
            guard link.start <= utf16.count else { return }
            let label = String(decoding: utf16[link.start...], as: UTF16.self)
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            let href = link.href.trimmingCharacters(in: .whitespaces)
            // Links to nowhere, to this page or to scripts are just their words.
            guard !trimmed.isEmpty, !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:"),
                  trimmed != href, !trimmed.contains("\n") else { return }
            let before = String(decoding: utf16[..<link.start], as: UTF16.self)
            let leading = label.prefix { $0 == " " }
            let trailing = label.reversed().prefix { $0 == " " }
            output = before + leading + "[" + trimmed + "](" + href.replacingOccurrences(of: " ", with: "%20") + ")" + String(trailing)
        }

        mutating func writeTable() {
            let rows = tableRows.filter { !$0.allSatisfy(\.isEmpty) }
            tableRows = []
            guard let header = rows.first else { return }
            let width = rows.map(\.count).max() ?? 0
            func line(_ cells: [String]) -> String {
                let padded = cells + Array(repeating: "", count: width - cells.count)
                return "| " + padded.joined(separator: " | ") + " |"
            }
            blankLine()
            write(line(header))
            newline()
            write("|" + Array(repeating: " --- |", count: width).joined())
            newline()
            for cells in rows.dropFirst() {
                write(line(cells))
                newline()
            }
            blankLine()
        }

        mutating func finish() -> String {
            var lines = output.components(separatedBy: "\n").map { line -> String in
                var line = line
                while line.hasSuffix(" ") { line.removeLast() }
                return line
            }
            // No more than one blank line in a row, and none at the ends.
            var result: [String] = []
            for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
            while result.last?.isEmpty == true { result.removeLast() }
            lines = result
            return lines.joined(separator: "\n")
        }
    }
}
