import Foundation
import SwiftData

/// A study notebook, as MarginNote's: documents to read and a map of
/// cards made from them. Every highlight made while studying in it
/// becomes a card (see `StudyCard`), under the card chosen.
@Model
final class Notebook {
    var uuid: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    /// Its documents' order, as their uuids, one per line (as `ItemList`).
    var orderIDs: String = ""
    @Relationship(inverse: \Item.notebooks) var items: [Item]? = []
    @Relationship(deleteRule: .cascade, inverse: \StudyCard.notebook) var cards: [StudyCard]? = []

    init(name: String) {
        self.name = name
    }

    var order: [UUID] {
        get { orderIDs.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } }
        set { orderIDs = newValue.map(\.uuidString).joined(separator: "\n") }
    }

    /// Its documents in their order; any not in it after, oldest first.
    var orderedItems: [Item] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return (items ?? []).sorted { a, b in
            let first = position[a.uuid] ?? .max, second = position[b.uuid] ?? .max
            return first != second ? first < second : a.createdAt < b.createdAt
        }
    }
}

/// One card in a notebook's map: an excerpt (a highlight, kept as text so
/// the card outlives it), a heading of its own, or both, with a comment.
/// Cards nest; `linkIDs` joins cards anywhere in the map, as MarginNote's
/// card links do.
@Model
final class StudyCard {
    var uuid: UUID = UUID()
    var notebook: Notebook?
    var parent: StudyCard?
    @Relationship(deleteRule: .nullify, inverse: \StudyCard.parent) var children: [StudyCard]? = []
    /// Its place among its siblings.
    var order: Int = 0
    var title: String = ""
    var excerpt: String = ""
    var comment: String = ""
    /// A `HighlightColor`'s raw value.
    var colorRaw: String = "yellow"
    /// The highlight it was made from, and the document.
    var highlightID: UUID?
    var sourceItemID: UUID?
    /// A page in the document (from a table of contents), from 0; -1 for none.
    var sourcePage: Int = -1
    /// Cards it's linked to, as uuids, one per line.
    var linkIDs: String = ""
    var createdAt: Date = Date()

    init(title: String = "", excerpt: String = "") {
        self.title = title
        self.excerpt = excerpt
    }

    var links: [UUID] {
        get { linkIDs.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } }
        set { linkIDs = newValue.map(\.uuidString).joined(separator: "\n") }
    }
}
