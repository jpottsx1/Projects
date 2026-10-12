import Foundation

/// Markdown tables: `| a | b |` rows, under a `|---|---|` line.
public enum MarkdownTable {
    static func isRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.count > 1
    }

    static func isSeparator(_ line: String) -> Bool {
        guard isRow(line) else { return false }
        let cells = cells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } && cell.contains("-")
        }
    }

    /// The cells of a row, trimmed. `\|` is a pipe inside a cell.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces).dropFirst() {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { cells.append(last) }
        return cells
    }

    /// An empty table to start from.
    public static func template(columns: Int = 3, rows: Int = 2) -> String {
        let columns = max(columns, 1)
        let header = "| " + (1...columns).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let rule = "| " + Array(repeating: "--------", count: columns).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: "        ", count: columns).joined(separator: " | ") + " |"
        return ([header, rule] + Array(repeating: row, count: max(rows, 0))).joined(separator: "\n")
    }

    /// The table around `line` (a line index) with its columns lined up,
    /// and the range of lines it covers. Nil when `line` isn't in a table.
    public static func tidy(_ text: String, aroundLine line: Int) -> (text: String, lines: Range<Int>)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), isRow(lines[line].trimmingCharacters(in: .whitespaces)) else { return nil }
        var start = line, end = line + 1
        while start > 0, isRow(lines[start - 1].trimmingCharacters(in: .whitespaces)) { start -= 1 }
        while end < lines.count, isRow(lines[end].trimmingCharacters(in: .whitespaces)) { end += 1 }
        let rows = lines[start..<end].map { cells($0.trimmingCharacters(in: .whitespaces)) }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        let separatorIndex = rows.firstIndex { row in
            !row.isEmpty && row.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
        }
        var widths = Array(repeating: 3, count: columns)
        for (index, row) in rows.enumerated() where index != separatorIndex {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        let tidied = rows.enumerated().map { index, row -> String in
            let padded = (0..<columns).map { column -> String in
                let cell = column < row.count ? row[column] : ""
                if index == separatorIndex {
                    let left = cell.hasPrefix(":"), right = cell.hasSuffix(":") && cell.count > 1
                    let dashes = String(repeating: "-", count: widths[column] - (left ? 1 : 0) - (right ? 1 : 0))
                    return (left ? ":" : "") + dashes + (right ? ":" : "")
                }
                return cell + String(repeating: " ", count: widths[column] - cell.count)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var result = lines
        result.replaceSubrange(start..<end, with: tidied)
        return (result.joined(separator: "\n"), start..<end)
    }
}
