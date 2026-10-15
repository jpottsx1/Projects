import Foundation

/// Fields of your own on items, as DEVONthink's custom metadata: what
/// kinds there are, how values are kept (as text, so they sync and export
/// plainly), shown, sorted and searched.
public enum CustomField {
    public enum Kind: String, CaseIterable, Codable {
        case text, number, date, yesNo, choice
        /// Notion's database fields: links to other items, a summary of a
        /// field on them, and a value worked out from other fields.
        case relation, rollup, formula

        public var name: String {
            switch self {
            case .text: "Text"
            case .number: "Number"
            case .date: "Date"
            case .yesNo: "Yes or No"
            case .choice: "Choice"
            case .relation: "Relation"
            case .rollup: "Rollup"
            case .formula: "Formula"
            }
        }

        /// Worked out, never typed.
        public var isComputed: Bool { self == .rollup || self == .formula }
    }

    /// Dates are kept as 2026-10-12, which sorts and compares as text.
    public static func storedDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    public static func date(from stored: String, calendar: Calendar = .current) -> Date? {
        let parts = stored.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Numbers with either decimal mark ("12.5" or "12,5"), thousands
    /// separators ignored ("1,234.5", "1.234,5").
    public static func number(from stored: String) -> Double? {
        var text = stored.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        let dot = text.lastIndex(of: "."), comma = text.lastIndex(of: ",")
        if let dot, let comma {
            // Whichever comes last is the decimal mark.
            if dot > comma { text.removeAll { $0 == "," } } else {
                text.removeAll { $0 == "." }
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        } else if comma != nil {
            // One comma before three digits is a thousands separator (1,200); before others, a decimal mark (12,5).
            let after = text[text.index(after: comma!)...]
            let isDecimal = text.filter { $0 == "," }.count == 1 && after.count != 3
            text = isDecimal ? text.replacingOccurrences(of: ",", with: ".") : text.filter { $0 != "," }
        } else if text.filter({ $0 == "." }).count > 1 {
            text.removeAll { $0 == "." }
        }
        return Double(text)
    }

    /// How a value reads in a list or column.
    public static func display(_ stored: String, kind: Kind, locale: Locale = .current) -> String {
        guard !stored.isEmpty else { return "" }
        switch kind {
        case .yesNo:
            return stored == "true" ? "Yes" : "No"
        case .date:
            guard let date = date(from: stored) else { return stored }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        default:
            return stored
        }
    }

    /// Whether a value matches what was searched for: words it contains,
    /// "yes" or "no", or a comparison (`>10`, `<=2026-12-31`) for numbers
    /// and dates.
    public static func matches(_ stored: String, kind: Kind, filter: String) -> Bool {
        var wanted = filter.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return !stored.isEmpty }
        var comparison = "="
        for symbol in [">=", "<=", ">", "<", "="] where wanted.hasPrefix(symbol) {
            comparison = symbol
            wanted = String(wanted.dropFirst(symbol.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        switch kind {
        case .yesNo:
            let yes = ["yes", "true", "y", "1"].contains(wanted.lowercased())
            return (stored == "true") == yes
        case .number:
            guard let value = number(from: stored), let target = number(from: wanted) else { return false }
            return compare(value, target, comparison)
        case .date:
            guard !stored.isEmpty else { return false }
            // Compared as text: 2026, 2026-10 and 2026-10-12 all work.
            let prefix = String(stored.prefix(wanted.count))
            switch comparison {
            case ">": return prefix > wanted
            case "<": return prefix < wanted
            case ">=": return prefix >= wanted
            case "<=": return prefix <= wanted
            default: return prefix == wanted
            }
        case .text, .choice, .relation, .rollup, .formula:
            return stored.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func compare(_ value: Double, _ target: Double, _ comparison: String) -> Bool {
        switch comparison {
        case ">": value > target
        case "<": value < target
        case ">=": value >= target
        case "<=": value <= target
        default: value == target
        }
    }

    /// A relation's value: the related items' uuids.
    public static func relatedIDs(_ stored: String) -> [UUID] {
        stored.split(separator: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func storedRelation(_ ids: [UUID]) -> String {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }.map(\.uuidString).joined(separator: ",")
    }

    /// Values (`[field id: stored value]`) as kept on an item.
    public static func encode(_ values: [UUID: String]) -> String {
        let pairs = values.filter { !$0.value.isEmpty }.map { ($0.key.uuidString, $0.value) }
        let dictionary = Dictionary(uniqueKeysWithValues: pairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return dictionary.isEmpty ? "" : (try? encoder.encode(dictionary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func decode(_ text: String) -> [UUID: String] {
        guard !text.isEmpty, let dictionary = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
}
