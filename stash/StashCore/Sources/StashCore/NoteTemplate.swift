import Foundation

/// Fills in a template's placeholders when a note is made from it:
///
/// - `{{date}}`: today, as 2026-10-12 (the way daily notes are titled)
/// - `{{date:EEEE d MMMM}}`: today in any `DateFormatter` format
/// - `{{yesterday}}`, `{{tomorrow}}`: as `{{date}}`, for linking days
///   together: `[[{{yesterday}}]]`
/// - `{{time}}`: the time, as 14:05
/// - `{{weekday}}`: Monday
/// - `{{title}}`: the new note's title
/// - `{{clipboard}}`: the text on the clipboard
///
/// Names are matched ignoring case; anything else in braces is left alone.
public enum NoteTemplate {
    public struct Values {
        public var date: Date
        public var title: String
        public var clipboard: String
        public var calendar: Calendar
        public var locale: Locale

        public init(date: Date = Date(), title: String = "", clipboard: String = "",
                    calendar: Calendar = .current, locale: Locale = .current) {
            self.date = date
            self.title = title
            self.clipboard = clipboard
            self.calendar = calendar
            self.locale = locale
        }
    }

    /// The format daily notes are titled with unless another is chosen.
    public static let dailyTitleFormat = "yyyy-MM-dd"

    private static let placeholder = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z]+)\s*(?::([^{}]*))?\}\}"#)

    public static func fill(_ text: String, with values: Values) -> String {
        guard text.contains("{{") else { return text }
        let string = text as NSString
        var result = ""
        var cursor = 0
        for match in placeholder.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 1)).lowercased()
            let argument = match.range(at: 2).location == NSNotFound ? nil
                : string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard let replacement = value(of: name, argument: argument, values) else { continue }
            result += string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += string.substring(from: cursor)
        return result
    }

    /// Whether the text has anything to fill in.
    public static func hasPlaceholders(_ text: String) -> Bool {
        placeholder.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func value(of name: String, argument: String?, _ values: Values) -> String? {
        switch name {
        case "date":
            return format(values.date, argument.flatMap { $0.isEmpty ? nil : $0 } ?? dailyTitleFormat, values)
        case "yesterday", "tomorrow":
            guard let day = values.calendar.date(byAdding: .day, value: name == "yesterday" ? -1 : 1, to: values.date) else {
                return nil
            }
            return format(day, argument.flatMap { $0.isEmpty ? nil : $0 } ?? dailyTitleFormat, values)
        case "time":
            return format(values.date, argument.flatMap { $0.isEmpty ? nil : $0 } ?? "HH:mm", values)
        case "weekday":
            return format(values.date, "EEEE", values)
        case "title":
            return values.title
        case "clipboard":
            return values.clipboard
        default:
            return nil
        }
    }

    public static func format(_ date: Date, _ format: String, _ values: Values) -> String {
        let formatter = DateFormatter()
        formatter.calendar = values.calendar
        formatter.timeZone = values.calendar.timeZone
        formatter.locale = values.locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
