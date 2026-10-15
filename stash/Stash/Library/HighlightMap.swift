import Foundation
import SwiftData
import StashCore

/// Highlights gathered into concepts (see `ConceptMap`): how a notebook's
/// map can be started from highlights already made.
extension Library {
    struct HighlightMapData {
        var map: ConceptMap
        var highlights: [ConceptMap.Highlight]
        var documents: [UUID: Item]
        var records: [UUID: Highlight]
    }

    /// From these items' highlights (locked ones left out).
    func highlightMap(of items: [Item], maxConcepts: Int) -> HighlightMapData {
        var highlights: [ConceptMap.Highlight] = []
        var documents: [UUID: Item] = [:]
        var records: [UUID: Highlight] = [:]
        for item in items where !item.isTrashed && !item.isLocked && !item.isTemplate {
            for highlight in item.sortedHighlights where !highlight.text.isEmpty {
                highlights.append(ConceptMap.Highlight(id: highlight.uuid, documentID: item.uuid, documentTitle: item.displayTitle,
                                                       text: highlight.text, note: highlight.note))
                documents[item.uuid] = item
                records[highlight.uuid] = highlight
            }
        }
        return HighlightMapData(map: ConceptMap.build(highlights, maxConcepts: maxConcepts), highlights: highlights,
                                documents: documents, records: records)
    }

    /// Opens the highlight's document, scrolled to it.
    func reveal(_ highlight: Highlight) {
        guard let item = highlight.item else { return }
        show(item)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            revealedHighlight = highlight
        }
    }
}
