import Foundation
import UniformTypeIdentifiers
import StashCore

/// A search with the index's part worked out once, so the list can test
/// every item against it quickly.
struct CompiledSearch {
    let query: SearchQuery
    /// Each matching item's place in the index's results, best first; nil
    /// when nothing is being searched for by word.
    let ranks: [UUID: Int]?
    /// Items with a left-out word or phrase.
    let excluded: Set<UUID>
    /// False when the index failed to open: words are then matched by plain
    /// text comparison, without ranking.
    let usesIndex: Bool
    private let after: Date?
    private let before: Date?

    init(_ query: SearchQuery, index: SearchIndex?, now: Date = .now, calendar: Calendar = .current) {
        self.query = query
        usesIndex = index != nil
        if let index, let expression = query.ftsExpression {
            var ranks: [UUID: Int] = [:]
            for (position, id) in index.search(expression).enumerated() where ranks[id] == nil {
                ranks[id] = position
            }
            self.ranks = ranks
        } else {
            ranks = nil
        }
        if let index, let expression = query.excludedExpression {
            excluded = Set(index.search(expression, limit: 100_000))
        } else {
            excluded = []
        }
        after = query.after?.start(now: now, calendar: calendar)
        before = query.before?.start(now: now, calendar: calendar)
    }

    static let none = CompiledSearch(SearchQuery(""), index: nil)

    var isEmpty: Bool { query.isEmpty }

    /// Whether results come best match first, rather than in the list's own order.
    var isRanked: Bool { ranks != nil }

    func matches(_ item: Item) -> Bool {
        if !query.tags.allSatisfy(item.hasTag(key:)) { return false }
        if query.excludedTags.contains(where: item.hasTag(key:)) { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(where: { $0.matches(item) }) { return false }
        if !query.categories.isEmpty {
            var names: Set<String> = []
            var next = item.category
            while let category = next {
                names.insert(category.name.lowercased())
                next = category.parent
            }
            if !query.categories.contains(where: names.contains) { return false }
        }
        for flag in query.flags {
            switch flag {
            case .favorite: if !item.isFavorite { return false }
            case .unread: if !item.isUnread { return false }
            case .read: if item.isUnread { return false }
            case .inbox: if !item.inInbox { return false }
            case .untagged: if !(item.tags ?? []).isEmpty { return false }
            case .uncategorized: if item.category != nil { return false }
            }
        }
        if !query.labels.isEmpty, !query.labels.contains(item.label) { return false }
        if let minimum = query.minimumRating, item.rating < minimum { return false }
        if let after, item.modifiedAt < after { return false }
        if let before, item.modifiedAt >= before { return false }

        if usesIndex {
            if let ranks, ranks[item.uuid] == nil { return false }
            return !excluded.contains(item.uuid)
        }
        let text = [item.title, item.body, item.summary, item.extractedText]
        let contains = { (term: SearchQuery.Term) in text.contains { $0.localizedStandardContains(term.text) } }
        return query.groups.allSatisfy { $0.contains(where: contains) }
            && !query.excludedTerms.contains(where: contains)
    }

    /// Best match first; items the index didn't rank last.
    func rank(_ items: [Item]) -> [Item] {
        guard let ranks else { return items }
        return items.sorted { ranks[$0.uuid, default: .max] < ranks[$1.uuid, default: .max] }
    }
}

extension SearchQuery.Kind {
    func matches(_ item: Item) -> Bool {
        switch self {
        case .note: return item.kind == .note
        case .link: return item.kind == .link
        case .document: return item.kind == .document
        case .pdf: return conforms(item, to: .pdf)
        case .image: return conforms(item, to: .image)
        case .video: return conforms(item, to: .movie)
        case .audio: return conforms(item, to: .audio)
        }
    }

    private func conforms(_ item: Item, to type: UTType) -> Bool {
        item.kind == .document && item.contentType?.conforms(to: type) == true
    }
}

/// How the list is ordered when it isn't showing search results best first.
enum ItemSort: String, CaseIterable, Identifiable {
    case modified, created, title, kind, rating, label

    var id: String { rawValue }

    var name: String {
        switch self {
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .title: "Title"
        case .kind: "Kind"
        case .rating: "Rating"
        case .label: "Label"
        }
    }

    /// Newest first for dates, A to Z otherwise.
    var naturallyAscending: Bool { self == .title || self == .kind || self == .label }

    func ascendingName(_ ascending: Bool) -> String {
        switch self {
        case .modified, .created: ascending ? "Oldest First" : "Newest First"
        case .title, .kind: ascending ? "A to Z" : "Z to A"
        case .rating: ascending ? "Lowest First" : "Highest First"
        case .label: ascending ? "Red First" : "Gray First"
        }
    }

    func sorted(_ items: [Item], ascending: Bool) -> [Item] {
        let ordered: (Item, Item) -> Bool
        switch self {
        case .modified: ordered = { $0.modifiedAt < $1.modifiedAt }
        case .created: ordered = { $0.createdAt < $1.createdAt }
        case .title: ordered = { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .rating:
            ordered = { a, b in
                a.rating != b.rating ? a.rating < b.rating : a.modifiedAt < b.modifiedAt
            }
        case .label:
            // Unlabelled items after every colour, whichever way round.
            let rank = { (item: Item) in item.labelRaw == 0 ? (ascending ? Int.max : Int.min) : item.labelRaw }
            ordered = { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b)
                    : a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            }
        case .kind:
            ordered = { a, b in
                let first = Self.kindName(a), second = Self.kindName(b)
                if first != second { return first.localizedStandardCompare(second) == .orderedAscending }
                return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            }
        }
        return items.sorted(by: ascending ? ordered : { ordered($1, $0) })
    }

    /// "Note", "Link", or the document's file type ("PDF document").
    private static func kindName(_ item: Item) -> String {
        item.kind == .document ? (item.contentType?.localizedDescription ?? "Document") : item.kind.rawValue
    }
}
