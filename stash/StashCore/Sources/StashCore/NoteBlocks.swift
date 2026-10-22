import Foundation

/// A note as Notion-style blocks, to move, turn into other kinds, and edit
/// one at a time; joined back into the note's Markdown as they change.
/// Toggles are kept as `<details><summary>…</summary>…</details>`, which
/// other Markdown apps (GitHub, Obsidian) show as collapsible too.
public struct NoteBlock: Equatable, Identifiable {
    public enum Kind: String, CaseIterable, Identifiable {
        case text, heading1, heading2, heading3, bullet, numbered, todo, quote, code, toggle, divider
        /// Anything else (a table, a picture, deeper headings): its Markdown as written.
        case raw

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .text: "Text"
            case .heading1: "Heading 1"
            case .heading2: "Heading 2"
            case .heading3: "Heading 3"
            case .bullet: "Bulleted List"
            case .numbered: "Numbered List"
            case .todo: "To-do"
            case .quote: "Quote"
            case .code: "Code"
            case .toggle: "Toggle"
            case .divider: "Divider"
            case .raw: "Markdown"
            }
        }

        var isListItem: Bool { self == .bullet || self == .numbered || self == .todo }
    }

    public var id: UUID
    public var kind: Kind
    /// The text, without its Markdown marks; a toggle's title; code itself.
    public var text: String
    /// A toggle's contents (Markdown); a code block's language.
    public var body: String
    /// List items' nesting, from 0.
    public var indent: Int
    public var done: Bool

    public init(id: UUID = UUID(), kind: Kind, text: String = "", body: String = "", indent: Int = 0, done: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.body = body
        self.indent = indent
        self.done = done
    }

    /// The same words as another kind of block.
    public func converted(to kind: Kind) -> NoteBlock {
        var block = self
        switch (self.kind, kind) {
        case (.toggle, _) where kind != .toggle:
            block.text = [text, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
            block.body = ""
        case (.code, _) where kind != .code:
            block.body = ""
        case (_, .code):
            block.body = ""
        default:
            break
        }
        if kind == .divider { block.text = "" }
        if !kind.isListItem { block.indent = 0 }
        block.kind = kind
        return block
    }
}

public enum NoteBlocks {
    public static func split(_ markdown: String) -> [NoteBlock] {
        splitWithLines(markdown).map(\.block)
    }

    /// The blocks, and the line each starts on.
    public static func splitWithLines(_ markdown: String) -> [(block: NoteBlock, line: Int)] {
        let lines = MarkdownBlocks.sourceLines(markdown)
        var blocks: [(block: NoteBlock, line: Int)] = []
        var paragraph: [String] = []
        var paragraphStart = 0
        var quote: [String] = []
        var quoteStart = 0
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append((NoteBlock(kind: .text, text: paragraph.joined(separator: "\n")), paragraphStart)) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append((NoteBlock(kind: .quote, text: quote.joined(separator: "\n")), quoteStart)) }
            quote = []
        }
        func flush() {
            // In the order they started.
            if paragraphStart <= quoteStart { flushParagraph(); flushQuote() } else { flushQuote(); flushParagraph() }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = MarkdownBlocks.indentLevel(line)
            let begin = index

            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append((NoteBlock(kind: .code, text: code.joined(separator: "\n"), body: language), begin))
                index += 1
                continue
            }
            if trimmed.lowercased().hasPrefix("<details") {
                flush()
                let (title, body, next) = toggle(at: index, in: lines)
                blocks.append((NoteBlock(kind: .toggle, text: title, body: body), begin))
                index = next
                continue
            }
            if MarkdownTable.isRow(trimmed), index + 1 < lines.count,
               MarkdownTable.isSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flush()
                var table = [line]
                index += 1
                while index < lines.count, MarkdownTable.isRow(lines[index].trimmingCharacters(in: .whitespaces))
                        || MarkdownTable.isSeparator(lines[index].trimmingCharacters(in: .whitespaces)) {
                    table.append(lines[index])
                    index += 1
                }
                blocks.append((NoteBlock(kind: .raw, text: table.joined(separator: "\n")), begin))
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let (level, text) = MarkdownBlocks.heading(trimmed) {
                flush()
                switch level {
                case 1: blocks.append((NoteBlock(kind: .heading1, text: text), begin))
                case 2: blocks.append((NoteBlock(kind: .heading2, text: text), begin))
                case 3: blocks.append((NoteBlock(kind: .heading3, text: text), begin))
                default: blocks.append((NoteBlock(kind: .raw, text: trimmed), begin))
                }
            } else if MarkdownBlocks.isRule(trimmed) {
                flush()
                blocks.append((NoteBlock(kind: .divider), begin))
            } else if MarkdownBlocks.image(trimmed) != nil {
                flush()
                blocks.append((NoteBlock(kind: .raw, text: trimmed), begin))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                if quote.isEmpty { quoteStart = begin }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let (done, text) = MarkdownBlocks.task(trimmed) {
                flush()
                blocks.append((NoteBlock(kind: .todo, text: text, indent: indent, done: done), begin))
            } else if let text = MarkdownBlocks.bullet(trimmed) {
                flush()
                blocks.append((NoteBlock(kind: .bullet, text: text, indent: indent), begin))
            } else if let (_, text) = MarkdownBlocks.numbered(trimmed) {
                flush()
                blocks.append((NoteBlock(kind: .numbered, text: text, indent: indent), begin))
            } else if line.first?.isWhitespace == true, paragraph.isEmpty, quote.isEmpty,
                      let last = blocks.last, last.block.kind.isListItem {
                // A list item's text running on to the next line.
                blocks[blocks.count - 1].block.text += "\n" + trimmed
            } else {
                flushQuote()
                if paragraph.isEmpty { paragraphStart = begin }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// The note with the block on `line` moved up (-1) or down (1) a place.
    /// Nil when there's nowhere to move it. Gives the line it starts on after.
    public static func movingBlock(at line: Int, by offset: Int, in markdown: String) -> (text: String, line: Int)? {
        let found = splitWithLines(markdown)
        guard let index = found.lastIndex(where: { $0.line <= line }), found.indices.contains(index + offset) else { return nil }
        let moved = moving(found.map(\.block), from: index, to: index + offset)
        let text = join(moved)
        let newStart = splitWithLines(text)[index + offset].line
        return (text, newStart)
    }

    /// A `<details>` section starting at `start`: its title, its contents,
    /// and the line after it.
    static func toggle(at start: Int, in lines: [String]) -> (title: String, body: String, next: Int) {
        let opening = lines[start].trimmingCharacters(in: .whitespaces)
        var inside: [String] = []
        if let close = opening.firstIndex(of: ">") {
            let rest = String(opening[opening.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { inside.append(rest) }
        }
        var index = start + 1
        var depth = 1
        while index < lines.count {
            let lowered = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
            if lowered.hasPrefix("<details") { depth += 1 }
            if lowered.hasPrefix("</details>") {
                depth -= 1
                if depth == 0 { break }
            }
            inside.append(lines[index])
            index += 1
        }
        while inside.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { inside.removeFirst() }
        var title = ""
        if let first = inside.first, let summary = summaryText(first.trimmingCharacters(in: .whitespaces)) {
            title = summary
            inside.removeFirst()
        }
        while inside.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { inside.removeFirst() }
        while inside.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { inside.removeLast() }
        return (title, inside.joined(separator: "\n"), index + 1)
    }

    private static func summaryText(_ line: String) -> String? {
        let lowered = line.lowercased()
        guard lowered.hasPrefix("<summary>"), let end = lowered.range(of: "</summary>") else { return nil }
        let start = line.index(line.startIndex, offsetBy: "<summary>".count)
        let stop = line.index(line.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: end.lowerBound))
        return String(line[start..<stop]).trimmingCharacters(in: .whitespaces)
    }

    public static func join(_ blocks: [NoteBlock]) -> String {
        var parts: [String] = []
        var numbers: [Int: Int] = [:]
        var previous: NoteBlock?
        for block in blocks {
            if block.kind != .numbered { numbers = [:] }
            let pad = String(repeating: "  ", count: block.indent)
            let continued = { (text: String, marker: String) -> String in
                // Lines after the first sit under the text, past the marker.
                text.components(separatedBy: "\n").enumerated()
                    .map { $0.offset == 0 ? pad + marker + $0.element : pad + String(repeating: " ", count: marker.count) + $0.element }
                    .joined(separator: "\n")
            }
            let text: String
            switch block.kind {
            case .text: text = block.text
            case .heading1: text = "# " + block.text
            case .heading2: text = "## " + block.text
            case .heading3: text = "### " + block.text
            case .bullet: text = continued(block.text, "- ")
            case .todo: text = continued(block.text, block.done ? "- [x] " : "- [ ] ")
            case .numbered:
                for level in numbers.keys where level > block.indent { numbers[level] = nil }
                let number = (numbers[block.indent] ?? 0) + 1
                numbers[block.indent] = number
                text = continued(block.text, "\(number). ")
            case .quote: text = block.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .code: text = "```" + block.body + "\n" + block.text + "\n```"
            case .toggle:
                text = "<details>\n<summary>" + block.text + "</summary>\n\n" + block.body + (block.body.isEmpty ? "" : "\n\n") + "</details>"
            case .divider: text = "---"
            case .raw: text = block.text
            }
            if let previous {
                parts.append(previous.kind.isListItem && block.kind.isListItem ? "\n" : "\n\n")
            }
            parts.append(text)
            previous = block
        }
        return parts.joined()
    }

    /// Moves a block from one place to another.
    public static func moving(_ blocks: [NoteBlock], from source: Int, to destination: Int) -> [NoteBlock] {
        guard blocks.indices.contains(source) else { return blocks }
        var result = blocks
        let block = result.remove(at: source)
        result.insert(block, at: min(max(destination, 0), result.count))
        return result
    }
}
