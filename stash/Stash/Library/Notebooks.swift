import Foundation
import PDFKit
import SwiftData
import StashCore

/// A page to show in a PDF.
struct PageRequest: Equatable {
    let itemID: UUID
    let page: Int
    let id = UUID()
}

/// Study notebooks, as MarginNote's: documents, and a map of cards made
/// from what's highlighted in them.
extension Library {
    // MARK: - Notebooks

    @discardableResult
    func newNotebook(named name: String = "", with items: [Item] = []) -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(name: trimmed.isEmpty ? (items.first.map { $0.displayTitle } ?? "New Notebook") : trimmed)
        context.insert(notebook)
        add(items, to: notebook)
        save()
        sidebar = .notebook(notebook)
        selection = items.first
        return notebook
    }

    func add(_ items: [Item], to notebook: Notebook) {
        let new = items.filter { !(notebook.items ?? []).contains($0) && !$0.isTrashed }
        guard !new.isEmpty else { return }
        notebook.items = (notebook.items ?? []) + new
        notebook.order = notebook.order + new.map(\.uuid)
        save()
    }

    func remove(_ items: [Item], from notebook: Notebook) {
        notebook.items = (notebook.items ?? []).filter { !items.contains($0) }
        let ids = Set(items.map(\.uuid))
        notebook.order = notebook.order.filter { !ids.contains($0) }
        save()
    }

    func rename(_ notebook: Notebook, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notebook.name = trimmed
        save()
    }

    /// Its cards go with it; its documents stay.
    func delete(_ notebook: Notebook) {
        if sidebar == .notebook(notebook) { sidebar = .all }
        context.delete(notebook)
        save()
    }

    func notebooks() -> [Notebook] {
        ((try? context.fetch(FetchDescriptor<Notebook>())) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The notebook being studied, if the sidebar is showing one.
    var studiedNotebook: Notebook? {
        if case .notebook(let notebook) = sidebar { return notebook }
        return nil
    }

    // MARK: - Cards

    static func plan(_ cards: [StudyCard]) -> [StudyMap.Card] {
        cards.map { StudyMap.Card(id: $0.uuid, parent: $0.parent?.uuid, order: $0.order, title: $0.title, excerpt: $0.excerpt) }
    }

    func card(_ id: UUID?, in notebook: Notebook) -> StudyCard? {
        guard let id else { return nil }
        return (notebook.cards ?? []).first { $0.uuid == id }
    }

    /// A card at the end of `parent`'s (or the top's).
    @discardableResult
    func addCard(title: String = "", excerpt: String = "", under parent: StudyCard?, in notebook: Notebook) -> StudyCard {
        let card = StudyCard(title: title, excerpt: excerpt)
        context.insert(card)
        card.notebook = notebook
        card.parent = parent
        let siblings = (notebook.cards ?? []).filter { $0.parent == parent && $0 != card }
        card.order = (siblings.map(\.order).max() ?? -1) + 1
        save()
        revision += 1
        return card
    }

    /// The excerpt as a card, under the card chosen.
    @discardableResult
    func addCard(from highlight: Highlight, in notebook: Notebook) -> StudyCard? {
        guard !(notebook.cards ?? []).contains(where: { $0.highlightID == highlight.uuid }) else { return nil }
        let card = addCard(excerpt: highlight.text, under: card(chosenCardID, in: notebook), in: notebook)
        card.comment = highlight.note
        card.colorRaw = highlight.colorRaw
        card.highlightID = highlight.uuid
        card.sourceItemID = highlight.item?.uuid
        save()
        return card
    }

    /// Cards for highlights in the notebook's documents that have none yet.
    func collectHighlights(in notebook: Notebook) -> Int {
        var count = 0
        for item in notebook.orderedItems where !item.isLocked {
            for highlight in item.sortedHighlights where addCard(from: highlight, in: notebook) != nil { count += 1 }
        }
        return count
    }

    /// When a highlight goes, so do its cards; what was under them moves up.
    func removeCards(madeFrom highlight: Highlight) {
        let id = highlight.uuid
        let cards = (try? context.fetch(FetchDescriptor<StudyCard>(predicate: #Predicate { $0.highlightID == id }))) ?? []
        for card in cards { delete(card) }
    }

    func update(_ card: StudyCard, title: String? = nil, comment: String? = nil, color: String? = nil) {
        if let title { card.title = title }
        if let comment { card.comment = comment }
        if let color { card.colorRaw = color }
        save()
        revision += 1
    }

    /// The cards under it move up to its place.
    func delete(_ card: StudyCard) {
        for child in card.children ?? [] { child.parent = card.parent }
        if chosenCardID == card.uuid { chosenCardID = card.parent?.uuid }
        for other in card.notebook?.cards ?? [] where other.links.contains(card.uuid) {
            other.links = other.links.filter { $0 != card.uuid }
        }
        context.delete(card)
        save()
        revision += 1
    }

    /// Puts it under `target` (nil for the top), last, or before `before`.
    @discardableResult
    func move(_ card: StudyCard, under target: StudyCard?, before: StudyCard? = nil) -> Bool {
        guard let notebook = card.notebook,
              StudyMap.canMove(card.uuid, under: target?.uuid, in: Self.plan(notebook.cards ?? [])) else { return false }
        card.parent = target
        var siblings = (notebook.cards ?? []).filter { $0.parent == target && $0 != card }
            .sorted { ($0.order, $0.uuid.uuidString) < ($1.order, $1.uuid.uuidString) }
        let index = before.flatMap { siblings.firstIndex(of: $0) } ?? siblings.count
        siblings.insert(card, at: index)
        for (order, sibling) in siblings.enumerated() { sibling.order = order }
        save()
        revision += 1
        return true
    }

    /// One place up or down among its siblings.
    func shift(_ card: StudyCard, by offset: Int) {
        guard let notebook = card.notebook else { return }
        var siblings = (notebook.cards ?? []).filter { $0.parent == card.parent }
            .sorted { ($0.order, $0.uuid.uuidString) < ($1.order, $1.uuid.uuidString) }
        guard let index = siblings.firstIndex(of: card), siblings.indices.contains(index + offset) else { return }
        siblings.swapAt(index, index + offset)
        for (order, sibling) in siblings.enumerated() { sibling.order = order }
        save()
        revision += 1
    }

    /// Under the card before it (indent), or beside its parent (outdent).
    func indent(_ card: StudyCard) {
        guard let notebook = card.notebook else { return }
        let siblings = (notebook.cards ?? []).filter { $0.parent == card.parent }
            .sorted { ($0.order, $0.uuid.uuidString) < ($1.order, $1.uuid.uuidString) }
        guard let index = siblings.firstIndex(of: card), index > 0 else { return }
        move(card, under: siblings[index - 1])
    }

    func outdent(_ card: StudyCard) {
        guard let parent = card.parent, let notebook = card.notebook else { return }
        let siblings = (notebook.cards ?? []).filter { $0.parent == parent.parent }
            .sorted { ($0.order, $0.uuid.uuidString) < ($1.order, $1.uuid.uuidString) }
        let after = siblings.firstIndex(of: parent).map { siblings.index(after: $0) }
        move(card, under: parent.parent, before: after.flatMap { siblings.indices.contains($0) ? siblings[$0] : nil })
    }

    /// Its excerpt and comment go into its parent's, and its cards under it.
    func mergeIntoParent(_ card: StudyCard) {
        guard let parent = card.parent else { return }
        if !card.excerpt.isEmpty { parent.excerpt += (parent.excerpt.isEmpty ? "" : "\n\n") + card.excerpt }
        if !card.comment.isEmpty { parent.comment += (parent.comment.isEmpty ? "" : "\n\n") + card.comment }
        if parent.title.isEmpty { parent.title = card.title }
        for child in card.children ?? [] { child.parent = parent }
        context.delete(card)
        save()
        revision += 1
    }

    /// Joins two cards, both ways.
    func link(_ card: StudyCard, to other: StudyCard) {
        guard card != other else { return }
        if !card.links.contains(other.uuid) { card.links += [other.uuid] }
        if !other.links.contains(card.uuid) { other.links += [card.uuid] }
        save()
        revision += 1
    }

    func unlink(_ card: StudyCard, _ other: StudyCard) {
        card.links = card.links.filter { $0 != other.uuid }
        other.links = other.links.filter { $0 != card.uuid }
        save()
        revision += 1
    }

    /// Opens the card's document beside the map, at its passage or page.
    func goToSource(of card: StudyCard) {
        guard let id = card.sourceItemID, let item = items(withIDs: [id]).first else { return }
        selection = item
        if let highlightID = card.highlightID,
           let highlight = (item.highlights ?? []).first(where: { $0.uuid == highlightID }) {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                revealedHighlight = highlight
            }
        } else if card.sourcePage >= 0 {
            let page = card.sourcePage
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                revealedPage = PageRequest(itemID: id, page: page)
            }
        }
    }

    // MARK: - Automatic maps

    /// A card for each heading in a PDF's table of contents, nested as it is,
    /// under the card chosen. Gives how many.
    func mapContents(of item: Item, in notebook: Notebook) -> Int {
        guard item.isPDF, let url = localFile(for: item), let document = PDFDocument(url: url),
              let outline = document.outlineRoot else { return 0 }
        var count = 0
        func add(_ node: PDFOutline, under parent: StudyCard?) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let card = addCard(title: child.label ?? "", under: parent, in: notebook)
                card.sourceItemID = item.uuid
                if let page = child.destination?.page { card.sourcePage = document.index(for: page) }
                count += 1
                add(child, under: card)
            }
        }
        let top = addCard(title: item.displayTitle, under: card(chosenCardID, in: notebook), in: notebook)
        top.sourceItemID = item.uuid
        add(outline, under: top)
        save()
        return count
    }

    /// The notebook's highlights gathered into concepts (as the words they
    /// share): a card for each concept, its excerpts under it.
    func mapConcepts(in notebook: Notebook, maxConcepts: Int = 12) -> Int {
        let data = highlightMap(of: notebook.orderedItems, maxConcepts: maxConcepts)
        guard !data.map.concepts.isEmpty else { return 0 }
        let byHighlight = Dictionary((notebook.cards ?? []).compactMap { card in card.highlightID.map { ($0, card) } },
                                     uniquingKeysWith: { first, _ in first })
        let top = addCard(title: "Concepts", under: nil, in: notebook)
        for concept in data.map.concepts {
            let conceptCard = addCard(title: concept.name.capitalized, under: top, in: notebook)
            for id in concept.highlights {
                if let existing = byHighlight[id] {
                    move(existing, under: conceptCard)
                } else if let highlight = data.records[id], let made = addCard(from: highlight, in: notebook) {
                    move(made, under: conceptCard)
                }
            }
        }
        return data.map.concepts.count
    }

    // MARK: - Title links

    /// Where titles of cards (in any notebook) turn up in this document, page by page.
    func titleLinks(in item: Item) async -> [TitleLinks.Match] {
        let titles = ((try? context.fetch(FetchDescriptor<StudyCard>())) ?? []).map(\.title).filter { !$0.isEmpty }
        guard !titles.isEmpty else { return [] }
        var pages: [String] = []
        if item.isPDF, let url = localFile(for: item) {
            pages = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: url) else { return [String]() }
                return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            }.value
        } else {
            pages = [[item.title, item.body, item.extractedText].joined(separator: "\n")]
        }
        return await Task.detached(priority: .userInitiated) { TitleLinks.find(titles, in: pages) }.value
    }

    /// Cards (in any notebook) with this title.
    func cards(titled title: String) -> [StudyCard] {
        let key = title.lowercased()
        return ((try? context.fetch(FetchDescriptor<StudyCard>())) ?? []).filter { $0.title.lowercased() == key }
    }

    // MARK: - Exporting

    func outline(of notebook: Notebook) -> String {
        StudyMap.outline(Self.plan(notebook.cards ?? []), title: notebook.name)
    }

    /// The map as a mind map note.
    @discardableResult
    func saveAsMindMap(_ notebook: Notebook) -> Item {
        let markdown = StudyMap.mindMap(Self.plan(notebook.cards ?? []), title: notebook.name).map.markdown
        let note = Item(kind: .note, title: notebook.name + " Map")
        note.body = markdown
        note.isMindMap = true
        context.insert(note)
        reindex(note)
        for item in notebook.items ?? [] { link(note, to: item) }
        save()
        return note
    }
}
