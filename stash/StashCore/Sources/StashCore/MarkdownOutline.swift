import Foundation

/// A note's headings, for an outline to jump about a long note with.
public enum MarkdownOutline {
    public struct Heading: Equatable {
        public var level: Int
        public var title: String
        /// Character offset of the heading's line in the note.
        public var offset: Int
    }

    public static func headings(in text: String) -> [Heading] {
        var headings: [Heading] = []
        var offset = 0
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, let (level, title) = MarkdownBlocks.heading(trimmed), !title.isEmpty {
                headings.append(Heading(level: level, title: MarkdownStyling.plainText(title), offset: offset))
            }
            offset += line.count + 1
        }
        return headings
    }
}
