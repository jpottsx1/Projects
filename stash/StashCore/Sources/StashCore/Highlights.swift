import Foundation

/// A highlighted stretch of text, remembered by what it says and a little
/// of what's either side, rather than by position. Laid out differently --
/// a new font size, a narrower window -- it's still found; if the same
/// words appear twice, the surrounding text picks the right one.
///
/// Offsets are in UTF-16 code units, the way a web page's JavaScript counts.
public struct TextQuote: Codable, Equatable {
    public var exact: String
    public var prefix: String
    public var suffix: String

    public static let contextLength = 32

    public init(exact: String, prefix: String = "", suffix: String = "") {
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }

    /// The quote for `start..<end` of `text`.
    public init?(in text: String, start: Int, end: Int) {
        let units = Array(text.utf16)
        guard start >= 0, end <= units.count, start < end else { return nil }
        let before = max(0, start - Self.contextLength)
        let after = min(units.count, end + Self.contextLength)
        exact = String(decoding: units[start..<end], as: UTF16.self)
        prefix = String(decoding: units[before..<start], as: UTF16.self)
        suffix = String(decoding: units[end..<after], as: UTF16.self)
    }

    /// Where the quote is in `text`: the occurrence whose surroundings
    /// match best. Nil if the words aren't there any more.
    public func locate(in text: String) -> Range<Int>? {
        let haystack = Array(text.utf16)
        let needle = Array(exact.utf16)
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let before = Array(prefix.utf16)
        let after = Array(suffix.utf16)

        var best: (start: Int, score: Int)?
        var start = 0
        let last = haystack.count - needle.count
        while start <= last {
            if haystack[start] == needle[0], haystack[start..<start + needle.count].elementsEqual(needle) {
                // How many characters of the context match, working outwards.
                var score = 0
                for (offset, unit) in before.reversed().enumerated() {
                    let index = start - 1 - offset
                    guard index >= 0, haystack[index] == unit else { break }
                    score += 1
                }
                for (offset, unit) in after.enumerated() {
                    let index = start + needle.count + offset
                    guard index < haystack.count, haystack[index] == unit else { break }
                    score += 1
                }
                if best == nil || score > best!.score { best = (start, score) }
            }
            start += 1
        }
        return best.map { $0.start..<$0.start + needle.count }
    }
}

/// Where a highlight is, saved as JSON on the highlight.
public enum HighlightAnchor: Codable, Equatable {
    /// Rectangles in each page's own coordinates (PDF points, origin at
    /// the bottom left), one per line of highlighted text.
    case pdf([PDFPageRects])
    /// In an EPUB book: the chapter's path inside the book, and the quote
    /// within the chapter's text.
    case epub(chapter: String, quote: TextQuote)
    /// In a saved page's clean article: the quote within its text.
    case article(quote: TextQuote)

    public struct PDFPageRects: Codable, Equatable {
        public var page: Int
        public var rects: [Rect]

        public init(page: Int, rects: [Rect]) {
            self.page = page
            self.rects = rects
        }
    }

    public struct Rect: Codable, Equatable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}

/// The colours a highlight can be.
public enum HighlightColor: String, CaseIterable, Codable {
    case yellow, green, blue, pink, purple

    public var name: String { rawValue.capitalized }
}
