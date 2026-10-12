import Foundation
import SwiftData
import StashCore

/// Highlights gathered up: one item's as a note linked to it, the whole
/// library's as a Markdown file.
extension Library {
    private func summarySource(for item: Item) -> AnnotationSummary.Source {
        AnnotationSummary.Source(
            title: item.displayTitle,
            url: item.urlString,
            entries: item.sortedHighlights.map { highlight in
                AnnotationSummary.Entry(text: highlight.text, note: highlight.note, color: highlight.color,
                                        location: AnnotationSummary.location(of: highlight.anchor, position: highlight.position))
            })
    }

    /// The note of an item's highlights, linked to it, made the first time
    /// and brought up to date after that. Shown when it's done.
    @discardableResult
    func makeHighlightsNote(for item: Item) -> Item {
        let title = AnnotationSummary.noteTitle(for: item.displayTitle)
        let text = AnnotationSummary.note(for: summarySource(for: item))
        let note: Item
        if let existing = (item.linkedFrom ?? []).first(where: { $0.kind == .note && $0.title == title && !$0.isTrashed }) {
            note = existing
            note.body = text
            didEdit(note)
        } else {
            note = newNote(titled: title, text: text)
            note.category = item.category
            note.inInbox = false
            for tag in item.tags ?? [] { note.tags = (note.tags ?? []) + [tag] }
            link(note, to: item)
        }
        save()
        show(note)
        return note
    }

    /// One item's highlights as Markdown, for the clipboard.
    func highlightsMarkdown(for item: Item) -> String {
        AnnotationSummary.entries(summarySource(for: item).entries)
    }

    /// Every highlight in the library, an item to a heading, as a Markdown
    /// file in a temporary folder.
    func exportHighlights() throws -> URL {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt == nil })
        let items = ((try? context.fetch(descriptor)) ?? [])
            .filter { !($0.highlights ?? []).isEmpty && !isHidden($0) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        let text = AnnotationSummary.library(items.map(summarySource(for:)))
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Highlights.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Back and forward

    /// Called as the selection changes: the item left is where Back goes.
    func remember(from previous: Item?) {
        guard !isMovingThroughHistory, let previous, previous != selection else { return }
        if backStack.last != previous.uuid { backStack.append(previous.uuid) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() { move(back: true) }
    func goForward() { move(back: false) }

    /// To the newest item on one stack still in the library, putting where
    /// we were on the other.
    private func move(back: Bool) {
        while let id = back ? backStack.popLast() : forwardStack.popLast() {
            guard let item = items(withIDs: [id]).first, isAlive(item) else { continue }
            if let current = selection {
                if back { forwardStack.append(current.uuid) } else { backStack.append(current.uuid) }
            }
            isMovingThroughHistory = true
            show(item)
            isMovingThroughHistory = false
            return
        }
    }
}
