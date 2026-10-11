import Foundation
import SwiftData
import StashCore

/// A highlighted passage in a PDF or a book, with an optional note.
/// Kept in the library rather than written into the file, so the file
/// stays as it was imported and highlights sync like everything else.
@Model
final class Highlight {
    var uuid: UUID = UUID()
    var item: Item?
    /// The words highlighted.
    var text: String = ""
    var note: String = ""
    var colorRaw: String = HighlightColor.yellow.rawValue
    /// Where it is: a `HighlightAnchor` as JSON.
    var anchorJSON: String = ""
    /// Orders highlights as they come in the document: the page or chapter
    /// number, plus how far through it.
    var position: Double = 0
    var createdAt: Date = Date()

    init(text: String, anchor: HighlightAnchor, position: Double, color: HighlightColor) {
        self.text = text
        self.anchorJSON = anchor.json
        self.position = position
        self.colorRaw = color.rawValue
    }

    var anchor: HighlightAnchor? { HighlightAnchor(json: anchorJSON) }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }
}
