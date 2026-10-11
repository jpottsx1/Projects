import Foundation
import SwiftData
import UniformTypeIdentifiers

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case note, document, link

    var id: String { rawValue }

    var pluralName: String {
        switch self {
        case .note: "Notes"
        case .document: "Documents"
        case .link: "Links"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .document: "doc"
        case .link: "link"
        }
    }
}

/// Everything in the library is an Item: a note, an imported document or a
/// saved web link.
///
/// Laid out so iCloud sync can be switched on later without migrating:
/// every attribute has a default, every relationship is optional, and
/// nothing is marked unique -- CloudKit allows none of those.
@Model
final class Item {
    var uuid: UUID = UUID()
    var kindRaw: String = ItemKind.note.rawValue
    var title: String = ""
    /// Markdown. The whole content of a note; the comments on a link or document.
    var body: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    // Links
    var urlString: String?
    /// The page's own description, shown under its title.
    var summary: String = ""

    // Documents
    /// Where the file lives inside the app's own storage (see `FileStore`).
    var storedFilePath: String?
    var contentTypeIdentifier: String?

    /// Words that aren't typed by anyone but should still be searchable:
    /// a page's text, a PDF's text, text read out of an image.
    var extractedText: String = ""

    var category: ItemCategory?
    @Relationship(inverse: \Tag.items) var tags: [Tag]? = []
    /// Items this one has been linked to by hand. `[[Title]]` links written
    /// in a note are read from its text instead, so they can't go stale.
    @Relationship(inverse: \Item.linkedFrom) var linksTo: [Item]? = []
    var linkedFrom: [Item]? = []

    init(kind: ItemKind, title: String) {
        self.kindRaw = kind.rawValue
        self.title = title
    }

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var url: URL? { urlString.flatMap(URL.init(string:)) }

    var contentType: UTType? { contentTypeIdentifier.flatMap(UTType.init) }

    var sortedTags: [Tag] {
        (tags ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    var systemImage: String {
        guard kind == .document, let type = contentType else { return kind.systemImage }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }

    func hasTag(key: String) -> Bool {
        (tags ?? []).contains { $0.key == key }
    }
}
