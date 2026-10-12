import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

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
    var isFavorite: Bool = false
    /// When it was put in the Trash; nil when it isn't there. Items stay
    /// in the Trash for `Library.trashDays`, then go for good.
    var trashedAt: Date?
    /// Added from elsewhere -- shared, imported, saved by Shortcuts -- and
    /// not looked at yet. Selecting an item reads it.
    var isUnread: Bool = false
    /// Waiting to be filed: things arriving without a category land here
    /// until they're given one, or marked done.
    var inInbox: Bool = false
    /// An `ItemLabel`'s raw value; 0 for none.
    var labelRaw: Int = 0
    /// 0 to 5 stars; 0 for unrated.
    var rating: Int = 0
    /// When to be reminded to look at it again; nil for no reminder.
    /// Stays set once it's come round, until it's marked done.
    var remindAt: Date?
    /// Kept out of sight -- its contents, from search and Spotlight too --
    /// until unlocked with Face ID, Touch ID or the device password. The
    /// contents aren't encrypted; this is privacy, not secrecy.
    var isLocked: Bool = false

    // Links
    var urlString: String?
    /// The page's own description, shown under its title.
    var summary: String = ""
    /// The full copy of the page (a Safari web archive), inside the app's
    /// own storage, for reading offline.
    var archivePath: String?
    var archivedAt: Date?
    /// The page's article without the clutter (an `Article` as JSON), from
    /// the same visit as the saved copy. Nil for pages with no article.
    @Attribute(.externalStorage) var articleData: Data?
    /// A small JPEG for the list and grid: a document's first page, a
    /// picture, the top of a saved page.
    @Attribute(.externalStorage) var thumbnailData: Data?
    /// The copy's contents, which is what iCloud syncs, as with documents'
    /// `fileData`. Nil for copies too large to sync.
    @Attribute(.externalStorage) var archiveData: Data?

    // Documents
    /// Where the file lives inside the app's own storage (see `FileStore`).
    var storedFilePath: String?
    var contentTypeIdentifier: String?
    /// The file's contents, which is what iCloud syncs: another device
    /// writes them back out to `storedFilePath` the first time the document
    /// is opened there. Kept outside the database file and only read when
    /// asked for, so listing items never loads it. Nil for files too large
    /// to sync (see `Library.largestSyncedFile`).
    @Attribute(.externalStorage) var fileData: Data?
    /// The file's SHA-256, for finding the same file imported twice. Empty
    /// until worked out (see `Library.fillContentHash`).
    var contentHash: String = ""
    /// Where reading stopped in a book: "chapter path|fraction scrolled".
    var readingPosition: String = ""
    @Relationship(deleteRule: .cascade, inverse: \Highlight.item) var highlights: [Highlight]? = []
    /// Pictures in a note.
    @Relationship(deleteRule: .cascade, inverse: \NoteAttachment.item) var attachments: [NoteAttachment]? = []
    /// A note's earlier versions.
    @Relationship(deleteRule: .cascade, inverse: \NoteVersion.item) var versions: [NoteVersion]? = []

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

    var isTrashed: Bool { trashedAt != nil }

    /// A reminder that has come round.
    var isDue: Bool { remindAt.map { $0 <= .now } ?? false }

    var label: ItemLabel {
        get { ItemLabel(rawValue: labelRaw) ?? .none }
        set { labelRaw = newValue.rawValue }
    }

    /// Highlights in reading order.
    var sortedHighlights: [Highlight] {
        (highlights ?? []).sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    var article: Article? {
        get { articleData.flatMap { try? JSONDecoder().decode(Article.self, from: $0) } }
        set { articleData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var isPDF: Bool { kind == .document && contentType?.conforms(to: .pdf) == true }
    var isEPUB: Bool { kind == .document && contentType?.conforms(to: .epub) == true }

    /// The same for two copies of one page or one file; nil for notes, and
    /// for documents whose file hasn't been read yet.
    var duplicateKey: String? {
        switch kind {
        case .link: url.map { "link " + WebAddress.duplicateKey(for: $0) }
        case .document: contentHash.isEmpty ? nil : "file " + contentHash
        case .note: nil
        }
    }

    var contentType: UTType? { contentTypeIdentifier.flatMap { UTType($0) } }

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
