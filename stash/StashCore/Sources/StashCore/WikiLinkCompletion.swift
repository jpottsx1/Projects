import Foundation

/// Suggesting titles while a `[[link]]` is being typed.
public enum WikiLinkCompletion {
    /// An unfinished link just before the cursor: `[[shop` with the cursor
    /// after the p has the query "shop" and covers `[[shop`.
    public struct Context: Equatable {
        public var query: String
        public var range: Range<String.Index>
    }

    /// Links longer than this aren't worth scanning back for.
    static let maxQueryLength = 100

    /// The unfinished link the cursor is in, if any. Nil once the link is
    /// closed, crosses a line, or has reached its `|shown text` part.
    public static func context(in text: String, cursor: String.Index) -> Context? {
        // A cursor from before the latest edit may no longer fit the text.
        guard cursor >= text.startIndex, cursor <= text.endIndex,
              let cursor = String.Index(cursor, within: text) else { return nil }

        var position = cursor
        var scanned = 0
        while position > text.startIndex, scanned <= maxQueryLength {
            let previous = text.index(before: position)
            switch text[previous] {
            case let character where character.isNewline || character == "]" || character == "|":
                return nil
            case "[":
                guard previous > text.startIndex, text[text.index(before: previous)] == "[" else { return nil }
                let start = text.index(before: previous)
                return Context(query: String(text[position..<cursor]), range: start..<cursor)
            default:
                position = previous
                scanned += 1
            }
        }
        return nil
    }

    /// `text` with the unfinished link replaced by `[[title]]`, and where
    /// the cursor belongs afterwards: just past the closing brackets. A
    /// `]]` already right after the cursor is reused, not doubled.
    public static func complete(_ text: String, context: Context, with title: String) -> (text: String, cursor: String.Index) {
        var end = context.range.upperBound
        if text[end...].hasPrefix("]]") {
            end = text.index(end, offsetBy: 2)
        }
        let before = String(text[..<context.range.lowerBound])
        let link = "[[\(title)]]"
        let result = before + link + String(text[end...])
        let cursor = result.index(result.startIndex, offsetBy: before.count + link.count)
        return (result, cursor)
    }

    /// Where the cursor most likely is after an edit turned `old` into
    /// `new`: the end of the part that changed. For systems whose text
    /// editor doesn't say where its cursor is.
    public static func editPoint(from old: String, to new: String) -> String.Index {
        var oldStart = old.startIndex
        var newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex, old[oldStart] == new[newStart] {
            old.formIndex(after: &oldStart)
            new.formIndex(after: &newStart)
        }
        var oldEnd = old.endIndex
        var newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let oldPrevious = old.index(before: oldEnd)
            let newPrevious = new.index(before: newEnd)
            guard old[oldPrevious] == new[newPrevious] else { break }
            oldEnd = oldPrevious
            newEnd = newPrevious
        }
        return newEnd
    }

    /// The titles worth suggesting for `query`: those starting with it,
    /// then those with a word starting with it, then any containing it.
    /// Each group keeps the order given (most recently edited first, say).
    /// With nothing typed yet, simply the first few.
    public static func rank(_ titles: [String], for query: String, limit: Int = 8) -> [String] {
        let key = WikiLinks.key(query)
        var seen = Set<String>()
        let unique = titles.filter { !$0.isEmpty && seen.insert(WikiLinks.key($0)).inserted }
        guard !key.isEmpty else { return Array(unique.prefix(limit)) }

        var starts: [String] = []
        var wordStarts: [String] = []
        var contains: [String] = []
        for title in unique {
            let titleKey = WikiLinks.key(title)
            if titleKey.hasPrefix(key) {
                starts.append(title)
            } else if titleKey.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(key) }) {
                wordStarts.append(title)
            } else if titleKey.contains(key) {
                contains.append(title)
            }
        }
        return Array((starts + wordStarts + contains).prefix(limit))
    }
}
