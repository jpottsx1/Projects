import Foundation

/// The formatting buttons for a note: each turns Markdown on or off for
/// the selected text, and says what to select afterwards.
///
/// Positions are character offsets into the text (Swift `Character`s),
/// so they survive being turned into a `String.Index` on either side.
public enum MarkdownFormatting {
    public enum Style: CaseIterable {
        case bold, italic, code, link
        case heading, bulletList, numberedList, checkbox, quote
    }

    public struct Result: Equatable {
        public var text: String
        /// What to select afterwards; empty for a plain cursor.
        public var selection: Range<Int>
    }

    public static func apply(_ style: Style, to text: String, selection: Range<Int>) -> Result {
        let count = text.count
        let range = max(0, min(selection.lowerBound, count))..<max(0, min(selection.upperBound, count))
        switch style {
        case .bold: return wrap(text, range, with: "**")
        case .italic: return wrap(text, range, with: "_")
        case .code: return wrap(text, range, with: "`")
        case .link: return link(text, range)
        case .heading: return prefixLines(text, range, cycle: ["# ", "## ", "### "])
        case .bulletList: return prefixLines(text, range, cycle: ["- "])
        case .numberedList: return numberLines(text, range)
        case .checkbox: return prefixLines(text, range, cycle: ["- [ ] "])
        case .quote: return prefixLines(text, range, cycle: ["> "])
        }
    }

    // MARK: - Inline

    /// Puts `marker` either side of the selection, or takes it away if it's
    /// already there. With nothing selected, the cursor goes between a new
    /// pair, ready to type.
    static func wrap(_ text: String, _ range: Range<Int>, with marker: String) -> Result {
        var characters = Array(text)
        let mark = Array(marker)
        let width = mark.count

        // Already wrapped, just outside the selection: unwrap.
        if range.lowerBound >= width, range.upperBound + width <= characters.count,
           Array(characters[(range.lowerBound - width)..<range.lowerBound]) == mark,
           Array(characters[range.upperBound..<(range.upperBound + width)]) == mark {
            characters.removeSubrange(range.upperBound..<(range.upperBound + width))
            characters.removeSubrange((range.lowerBound - width)..<range.lowerBound)
            return Result(text: String(characters), selection: (range.lowerBound - width)..<(range.upperBound - width))
        }
        // The selection includes the markers: unwrap.
        if range.count >= 2 * width,
           Array(characters[range.lowerBound..<(range.lowerBound + width)]) == mark,
           Array(characters[(range.upperBound - width)..<range.upperBound]) == mark {
            characters.removeSubrange((range.upperBound - width)..<range.upperBound)
            characters.removeSubrange(range.lowerBound..<(range.lowerBound + width))
            return Result(text: String(characters), selection: range.lowerBound..<(range.upperBound - 2 * width))
        }
        // Spaces at the ends stay outside: "**word** ", not "**word **".
        var inner = range
        while inner.lowerBound < inner.upperBound, characters[inner.lowerBound].isWhitespace {
            inner = (inner.lowerBound + 1)..<inner.upperBound
        }
        while inner.lowerBound < inner.upperBound, characters[inner.upperBound - 1].isWhitespace {
            inner = inner.lowerBound..<(inner.upperBound - 1)
        }
        if inner.isEmpty && !range.isEmpty { inner = range }
        characters.insert(contentsOf: mark, at: inner.upperBound)
        characters.insert(contentsOf: mark, at: inner.lowerBound)
        return Result(text: String(characters), selection: (inner.lowerBound + width)..<(inner.upperBound + width))
    }

    /// `[selected text](url)` with "url" selected to type over; with nothing
    /// selected, `[](url)` with the cursor between the brackets. A selection
    /// that's already a web address becomes the address, with "link text"
    /// selected instead.
    static func link(_ text: String, _ range: Range<Int>) -> Result {
        var characters = Array(text)
        let selected = String(characters[range])
        let isAddress = WebAddress.url(from: selected) != nil && !selected.contains(" ")
        let label = isAddress ? "link text" : selected
        let target = isAddress ? selected : "url"
        let inserted = Array("[" + label + "](" + target + ")")
        characters.replaceSubrange(range, with: inserted)
        let start = range.lowerBound
        if isAddress {
            return Result(text: String(characters), selection: (start + 1)..<(start + 1 + label.count))
        }
        if selected.isEmpty {
            return Result(text: String(characters), selection: (start + 1)..<(start + 1))
        }
        let urlStart = start + 1 + label.count + 2
        return Result(text: String(characters), selection: urlStart..<(urlStart + target.count))
    }

    // MARK: - Lines

    /// The lines the selection touches, as offsets of their starts. A
    /// selection ending just after a line break doesn't count the next line.
    private static func lineStarts(_ characters: [Character], _ range: Range<Int>) -> [Int] {
        var start = range.lowerBound
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var starts = [start]
        let last = range.isEmpty ? range.lowerBound : range.upperBound - 1
        var index = start
        while index < last {
            if characters[index] == "\n" { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    private static func hasPrefix(_ characters: [Character], at start: Int, _ prefix: String) -> Bool {
        let mark = Array(prefix)
        return start + mark.count <= characters.count && Array(characters[start..<(start + mark.count)]) == mark
    }

    /// Adds a prefix to each line, or -- when every line already has it --
    /// moves on to the next in `cycle` (# to ## to ###), and past the last
    /// takes it away.
    static func prefixLines(_ text: String, _ range: Range<Int>, cycle: [String]) -> Result {
        var characters = Array(text)
        let starts = lineStarts(characters, range)
        // Which step of the cycle every line is on, if they agree.
        let current = cycle.indices.last { step in starts.allSatisfy { hasPrefix(characters, at: $0, cycle[step]) } }
        let next = current.map { $0 + 1 < cycle.count ? cycle[$0 + 1] : nil } ?? cycle.first

        var shift = 0
        var firstShift = 0
        for (number, start) in starts.enumerated() {
            let at = start + shift
            var change = 0
            if let current {
                let old = cycle[current].count
                characters.removeSubrange(at..<(at + old))
                change -= old
            }
            if let next {
                characters.insert(contentsOf: Array(next), at: at)
                change += next.count
            }
            if number == 0 { firstShift = change }
            shift += change
        }
        let lower = max(starts[0], range.lowerBound + firstShift)
        return Result(text: String(characters), selection: lower..<max(lower, range.upperBound + shift))
    }

    /// "1. ", "2. "... on each line, or takes the numbers away if every line has one.
    static func numberLines(_ text: String, _ range: Range<Int>) -> Result {
        var characters = Array(text)
        let starts = lineStarts(characters, range)
        func numberWidth(at start: Int) -> Int? {
            var index = start
            while index < characters.count, characters[index].isNumber { index += 1 }
            guard index > start, index + 1 < characters.count + 1,
                  hasPrefix(characters, at: index, ". ") else { return nil }
            return index - start + 2
        }
        let numbered = starts.allSatisfy { numberWidth(at: $0) != nil }
        var shift = 0
        var firstShift = 0
        for (number, start) in starts.enumerated() {
            let at = start + shift
            var change = 0
            if numbered, let width = numberWidth(at: at) {
                characters.removeSubrange(at..<(at + width))
                change = -width
            } else if !numbered {
                let prefix = Array("\(number + 1). ")
                characters.insert(contentsOf: prefix, at: at)
                change = prefix.count
            }
            if number == 0 { firstShift = change }
            shift += change
        }
        let lower = max(starts[0], range.lowerBound + firstShift)
        return Result(text: String(characters), selection: lower..<max(lower, range.upperBound + shift))
    }
}
