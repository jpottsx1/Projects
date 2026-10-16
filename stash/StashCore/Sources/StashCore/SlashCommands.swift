import Foundation

/// Notion's slash commands, in Write and Source: `/` at the start of a line
/// offers blocks to put there (`/head`, `/todo`, `/toggle`…).
public enum SlashCommands {
    public struct Command: Hashable {
        public var name: String
        public var keywords: [String]
        public var symbol: String
        /// What replaces `/query`; the cursor goes where `‸` is (and the `‸` goes).
        public var insert: String

        init(_ name: String, _ keywords: [String], _ symbol: String, _ insert: String) {
            self.name = name
            self.keywords = keywords
            self.symbol = symbol
            self.insert = insert
        }
    }

    public static let all: [Command] = [
        Command("Heading 1", ["h1", "heading", "title"], "textformat.size.larger", "# ‸"),
        Command("Heading 2", ["h2", "heading", "subtitle"], "textformat.size", "## ‸"),
        Command("Heading 3", ["h3", "heading"], "textformat.size.smaller", "### ‸"),
        Command("Bulleted List", ["bullet", "list", "ul"], "list.bullet", "- ‸"),
        Command("Numbered List", ["numbered", "list", "ol"], "list.number", "1. ‸"),
        Command("To-do", ["todo", "task", "checkbox", "check"], "checklist", "- [ ] ‸"),
        Command("Toggle", ["toggle", "details", "collapse", "fold"], "chevron.right.square",
                "<details>\n<summary>‸</summary>\n\n\n\n</details>"),
        Command("Quote", ["quote", "blockquote"], "text.quote", "> ‸"),
        Command("Code", ["code", "snippet"], "chevron.left.forwardslash.chevron.right", "```\n‸\n```"),
        Command("Divider", ["divider", "rule", "line", "hr"], "minus", "---\n‸"),
        Command("Table", ["table", "grid"], "tablecells", "| ‸ |  |\n| --- | --- |\n|  |  |"),
        Command("Link to Item", ["link", "page", "mention"], "link", "[[‸"),
        Command("Today’s Date", ["date", "today", "now"], "calendar", "{date}‸"),
    ]

    public struct Context: Equatable {
        public var query: String
        /// The `/query` typed so far.
        public var range: Range<String.Index>
    }

    /// The `/command` being typed at the start of the cursor's line, if one is.
    public static func context(in text: String, cursor: String.Index) -> Context? {
        guard cursor >= text.startIndex, cursor <= text.endIndex, let cursor = String.Index(cursor, within: text) else { return nil }
        let lineStart = text[..<cursor].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let typed = text[lineStart..<cursor]
        let indent = typed.prefix { $0 == " " || $0 == "\t" }
        let rest = typed.dropFirst(indent.count)
        guard rest.first == "/", rest.count <= 20, rest.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let slash = text.index(lineStart, offsetBy: indent.count)
        return Context(query: String(rest.dropFirst()), range: slash..<cursor)
    }

    /// Commands whose name or keywords start with what's typed; all for nothing.
    public static func matching(_ query: String) -> [Command] {
        let typed = query.lowercased()
        guard !typed.isEmpty else { return all }
        return all.filter { command in
            command.name.lowercased().split(separator: " ").contains { $0.hasPrefix(typed) }
                || command.keywords.contains { $0.hasPrefix(typed) }
        }
    }

    /// The text with `/query` replaced, and the cursor's offset in it.
    public static func apply(_ command: Command, to text: String, context: Context, today: String) -> (text: String, cursor: Int) {
        let insert = command.insert.replacingOccurrences(of: "{date}", with: today)
        let marker = insert.range(of: "‸")
        let clean = insert.replacingOccurrences(of: "‸", with: "")
        let before = String(text[..<context.range.lowerBound])
        let after = String(text[context.range.upperBound...])
        let cursor = before.count + (marker.map { insert.distance(from: insert.startIndex, to: $0.lowerBound) } ?? clean.count)
        return (before + clean + after, cursor)
    }
}
