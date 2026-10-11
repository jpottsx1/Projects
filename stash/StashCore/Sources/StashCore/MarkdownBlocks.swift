import Foundation

/// One block of a note, for the preview. Text inside a block is still inline
/// Markdown (bold, links, code spans), which the system renders.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: Int, text: String)
    /// `line` is the task's line in the source, so ticking it can edit the note.
    case task(indent: Int, done: Bool, text: String, line: Int)
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

/// The block structure of a note: enough Markdown for everyday notes, not
/// all of CommonMark.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = sourceLines(text)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))) }
            quote = []
        }
        func flush() {
            flushParagraph()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = indentLevel(line)

            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    text: code.joined(separator: "\n")))
                index += 1  // past the closing fence
                continue
            }

            if trimmed.isEmpty {
                flush()
            } else if case let (level, text)? = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: text))
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if case let (done, text)? = task(trimmed) {
                flush()
                blocks.append(.task(indent: indent, done: done, text: text, line: index))
            } else if let text = bullet(trimmed) {
                flush()
                blocks.append(.bullet(indent: indent, text: text))
            } else if case let (number, text)? = numbered(trimmed) {
                flush()
                blocks.append(.numbered(indent: indent, number: number, text: text))
            } else {
                flushQuote()
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// `text` with the task on `line` ticked or unticked. Anything that is
    /// not a task line is left alone.
    public static func toggleTask(onLine line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line),
              case let (done, _)? = task(lines[line].trimmingCharacters(in: .whitespaces)) else { return text }
        let box = done ? (lines[line].range(of: "[x]") ?? lines[line].range(of: "[X]"))
                       : lines[line].range(of: "[ ]")
        guard let box else { return text }
        lines[line].replaceSubrange(box, with: done ? "[ ]" : "[x]")
        return lines.joined(separator: "\n")
    }

    // MARK: - Lines

    static func sourceLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Two spaces or one tab per level.
    static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 2 } else { break }
        }
        return spaces / 2
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func task(_ line: String) -> (Bool, String)? {
        guard let item = bullet(line), item.count >= 3 else { return nil }
        let box = item.prefix(3)
        let done: Bool
        switch box {
        case "[ ]": done = false
        case "[x]", "[X]": done = true
        default: return nil
        }
        return (done, item.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
