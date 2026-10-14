import Foundation

/// DEVONthink's sheets: a CSV or TSV file as a table to edit. The first
/// row is the column headings.
public struct Sheet: Equatable {
    public var rows: [[String]]
    public var separator: Character

    public init(rows: [[String]], separator: Character = ",") {
        self.rows = rows
        self.separator = separator
        pad()
    }

    /// A new sheet: three headed columns and a few empty rows.
    public static func blank(columns: Int = 3, rows: Int = 5) -> Sheet {
        let headings = (0..<columns).map { "Column \($0 + 1)" }
        return Sheet(rows: [headings] + Array(repeating: Array(repeating: "", count: columns), count: rows))
    }

    // MARK: - Reading and writing

    /// Reads CSV (quoted fields, with doubled quotes and line breaks inside
    /// them) or, with `separator: "\t"`, TSV.
    public init(text: String, separator: Character = ",") {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let held = pending { pending = nil; return held }
            return characters.next()
        }
        while let character = next() {
            if inQuotes {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == separator {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        self.init(rows: rows.isEmpty ? [[""]] : rows, separator: separator)
    }

    public var text: String {
        rows.map { row in row.map(quoted).joined(separator: String(separator)) }.joined(separator: "\n") + "\n"
    }

    private func quoted(_ field: String) -> String {
        guard field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Every row as wide as the widest.
    private mutating func pad() {
        let width = max(rows.map(\.count).max() ?? 0, 1)
        if rows.isEmpty { rows = [Array(repeating: "", count: width)] }
        for index in rows.indices where rows[index].count < width {
            rows[index] += Array(repeating: "", count: width - rows[index].count)
        }
    }

    public var columnCount: Int { rows.first?.count ?? 0 }
    public var headings: [String] { rows.first ?? [] }

    // MARK: - Changes

    public mutating func set(_ value: String, row: Int, column: Int) {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        rows[row][column] = value
    }

    /// A blank row after `row` (or at the end).
    public mutating func insertRow(after row: Int? = nil) {
        let blank = Array(repeating: "", count: columnCount)
        if let row, rows.indices.contains(row) { rows.insert(blank, at: row + 1) } else { rows.append(blank) }
    }

    /// Any row but the headings.
    public mutating func deleteRow(_ row: Int) {
        guard row > 0, rows.indices.contains(row) else { return }
        rows.remove(at: row)
    }

    public mutating func insertColumn(after column: Int? = nil, heading: String = "") {
        let at = column.map { min($0 + 1, columnCount) } ?? columnCount
        for index in rows.indices { rows[index].insert(index == 0 ? heading : "", at: at) }
    }

    /// Any column but the last one left.
    public mutating func deleteColumn(_ column: Int) {
        guard columnCount > 1, (0..<columnCount).contains(column) else { return }
        for index in rows.indices { rows[index].remove(at: column) }
    }

    /// Sorts the rows under the headings by a column: numbers as numbers,
    /// text as Finder sorts names; empty cells last either way.
    public mutating func sort(byColumn column: Int, ascending: Bool) {
        guard rows.count > 2, (0..<columnCount).contains(column) else { return }
        let body = rows.dropFirst().sorted { a, b in
            let first = a[column], second = b[column]
            if first.isEmpty != second.isEmpty { return second.isEmpty }
            let ordered: Bool
            if let x = Double(first.replacingOccurrences(of: ",", with: "")),
               let y = Double(second.replacingOccurrences(of: ",", with: "")) {
                if x == y { return false }
                ordered = x < y
            } else {
                let comparison = first.localizedStandardCompare(second)
                if comparison == .orderedSame { return false }
                ordered = comparison == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
        rows = [rows[0]] + body
    }
}
