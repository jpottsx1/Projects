import Foundation

/// Tag names are single words, so `#tag` in a search can name any of them:
/// "to read" becomes "to-read". Case is kept for display and ignored when
/// comparing.
public enum TagName {
    public static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") { name.removeFirst() }
        return name.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
    }

    public static func key(_ raw: String) -> String {
        clean(raw).lowercased()
    }

    /// "work, to read,  #ideas" -> ["work", "to-read", "ideas"]
    public static func split(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { clean(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
