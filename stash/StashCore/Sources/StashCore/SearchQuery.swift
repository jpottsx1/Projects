import Foundation

/// What someone types in the search field.
///
/// - `budget report` -- items containing words starting with both
/// - `"budget report"` -- that exact phrase
/// - `#work` -- only items tagged "work" (combines with words)
public struct SearchQuery: Equatable {
    public enum Term: Equatable {
        case word(String)
        case phrase(String)
    }

    public private(set) var terms: [Term] = []
    /// Tag keys (see `TagName.key`).
    public private(set) var tags: [String] = []

    public init(_ text: String) {
        var terms: [Term] = []
        var tags: [String] = []
        var token = ""
        var inPhrase = false

        func finish() {
            defer { token = "" }
            if inPhrase {
                if !token.trimmingCharacters(in: .whitespaces).isEmpty { terms.append(.phrase(token)) }
            } else if token.hasPrefix("#"), token.count > 1 {
                let key = TagName.key(token)
                if !key.isEmpty, !tags.contains(key) { tags.append(key) }
            } else if !token.isEmpty {
                terms.append(.word(token))
            }
        }

        for character in text {
            if character == "\"" {
                finish()
                inPhrase.toggle()
            } else if character.isWhitespace && !inPhrase {
                finish()
            } else {
                token.append(character)
            }
        }
        finish()
        self.terms = terms
        self.tags = tags
    }

    public var isEmpty: Bool { terms.isEmpty && tags.isEmpty }

    /// An SQLite FTS5 `MATCH` expression for the words and phrases, or nil
    /// when there are none. Every term is quoted, so nothing typed can be
    /// read as FTS syntax; words also match as prefixes, so results appear
    /// while a word is still being typed.
    public var ftsExpression: String? {
        let parts: [String] = terms.compactMap { term in
            switch term {
            case .word(let word):
                return Self.isSearchable(word) ? Self.quoted(word) + "*" : nil
            case .phrase(let phrase):
                return Self.isSearchable(phrase) ? Self.quoted(phrase) : nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// An FTS5 expression matching `text` as a phrase within one column.
    public static func phrase(_ text: String, inColumn column: String) -> String? {
        isSearchable(text) ? "\(column) : \(quoted(text))" : nil
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// FTS5 rejects a quoted string with no words in it, such as `"-"`.
    static func isSearchable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
