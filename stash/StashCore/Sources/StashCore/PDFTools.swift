import Foundation

/// Page ranges as typed for splitting a PDF: `1-3, 5, 8-` (8 to the end).
public enum PageRanges {
    /// One-based, inclusive ranges, in the order typed; nil if any part
    /// isn't a range within the document.
    public static func parse(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, pageCount > 0 else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for part in parts where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let range: ClosedRange<Int>
            switch bounds.count {
            case 1:
                guard let page = Int(bounds[0]) else { return nil }
                range = page...page
            case 2:
                guard let first = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                      let last = bounds[1].isEmpty ? pageCount : Int(bounds[1]), first <= last else { return nil }
                range = first...last
            default:
                return nil
            }
            guard range.lowerBound >= 1, range.upperBound <= pageCount else { return nil }
            ranges.append(range)
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// Every page on its own.
    public static func singlePages(_ pageCount: Int) -> [ClosedRange<Int>] {
        (0..<max(pageCount, 0)).map { ($0 + 1)...($0 + 1) }
    }

    /// "Report, pages 1-3" -- a name for one part of a split.
    public static func name(_ title: String, _ range: ClosedRange<Int>) -> String {
        range.count == 1 ? "\(title), page \(range.lowerBound)" : "\(title), pages \(range.lowerBound)-\(range.upperBound)"
    }
}

/// DEVONthink's Imprinter: text stamped on every page of a PDF.
public struct Imprint: Equatable {
    public enum Position: String, CaseIterable, Identifiable {
        case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .topLeft: "Top Left"
            case .topCenter: "Top Center"
            case .topRight: "Top Right"
            case .center: "Across the Middle"
            case .bottomLeft: "Bottom Left"
            case .bottomCenter: "Bottom Center"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    /// May use `{page}`, `{pages}`, `{title}`, `{date}`.
    public var text: String
    public var position: Position
    public var fontSize: Double
    /// 0 to 1.
    public var opacity: Double
    /// An `ItemLabel`'s raw value for the colour; 0 for black.
    public var color: Int
    /// Leaves the first page alone, as for a title page.
    public var skipsFirstPage: Bool

    public init(text: String, position: Position = .bottomCenter, fontSize: Double = 10, opacity: Double = 1,
                color: Int = 0, skipsFirstPage: Bool = false) {
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.opacity = opacity
        self.color = color
        self.skipsFirstPage = skipsFirstPage
    }

    /// The text for one page, with the placeholders filled in.
    public func text(page: Int, of pages: Int, title: String, date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let dateText = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return text.replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{pages}", with: String(pages))
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{date}", with: dateText)
    }

    /// Where the text goes on a page `width` by `height`, given its size:
    /// the bottom-left corner of the text, with the origin at the bottom
    /// left as PDFs have it, `margin` in from the edges.
    public func origin(textWidth: Double, textHeight: Double, pageWidth: Double, pageHeight: Double,
                       margin: Double = 24) -> (x: Double, y: Double) {
        let left = margin, centre = (pageWidth - textWidth) / 2, right = pageWidth - margin - textWidth
        let top = pageHeight - margin - textHeight, bottom = margin, middle = (pageHeight - textHeight) / 2
        switch position {
        case .topLeft: return (left, top)
        case .topCenter: return (centre, top)
        case .topRight: return (right, top)
        case .center: return (centre, middle)
        case .bottomLeft: return (left, bottom)
        case .bottomCenter: return (centre, bottom)
        case .bottomRight: return (right, bottom)
        }
    }
}
