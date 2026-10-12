import AppIntents
import Foundation
import StashCore

/// Stash in the Shortcuts app, Siri and Spotlight's actions: add a note,
/// save a link, find items, open one. Each runs in the app itself, against
/// the same `Library` the window uses.

struct ItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stash Item"
    static let defaultQuery = ItemEntityQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Kind") var kind: String
    @Property(title: "Text") var text: String
    @Property(title: "Web Address") var url: URL?
    @Property(title: "Tags") var tags: [String]

    @MainActor
    init(_ item: Item) {
        id = item.uuid
        title = item.displayTitle
        kind = item.kind.rawValue.capitalized
        text = item.isLocked ? "" : item.body
        url = item.url
        tags = item.sortedTags.map(\.name)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind)")
    }
}

struct ItemEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ItemEntity] {
        StashStore.shared.library.items(withIDs: identifiers).map(ItemEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ItemEntity] {
        StashStore.shared.library.find(string, limit: 30).map(ItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ItemEntity] {
        StashStore.shared.library.find("", limit: 15).map(ItemEntity.init)
    }
}

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Adds a note to Stash.")

    @Parameter(title: "Title", default: "") var noteTitle: String
    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add note \(\.$text)") {
            \.$noteTitle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> {
        let library = StashStore.shared.library
        let item = library.newNote(titled: noteTitle, text: text)
        library.markReceived(item)
        return .result(value: ItemEntity(item))
    }
}

struct SaveLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Link"
    static let description = IntentDescription("Saves a web page to Stash, with a copy to read offline.")

    @Parameter(title: "Web Address") var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$url) to Stash")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> {
        // Shortcuts may hand over "example.com" with no https://, or a file.
        guard let web = WebAddress.url(from: url.absoluteString) else {
            throw $url.needsValueError("That isn’t a web address. Which page should be saved?")
        }
        let library = StashStore.shared.library
        let item = library.addLink(web)
        library.markReceived(item)
        return .result(value: ItemEntity(item))
    }
}

struct FindItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Items"
    static let description = IntentDescription("""
        Searches Stash as the search field does: words, "phrases", #tags, \
        kind:pdf, in:Category, is:favorite, after:7d and so on.
        """)

    @Parameter(title: "Search") var search: String
    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 200)) var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find items matching \(\.$search)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        .result(value: StashStore.shared.library.find(search, limit: limit).map(ItemEntity.init))
    }
}

struct OpenItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Item"
    static let description = IntentDescription("Opens an item in Stash.")
    static let openAppWhenRun = true

    @Parameter(title: "Item") var item: ItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = StashStore.shared.library
        if let found = library.items(withIDs: [item.id]).first { library.show(found) }
        return .result()
    }
}

struct StashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddNoteIntent(), phrases: [
            "Add a note to \(.applicationName)",
            "New \(.applicationName) note",
        ], shortTitle: "Add Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: SaveLinkIntent(), phrases: [
            "Save a link to \(.applicationName)",
        ], shortTitle: "Save Link", systemImageName: "link.badge.plus")
        AppShortcut(intent: FindItemsIntent(), phrases: [
            "Search \(.applicationName)",
            "Find in \(.applicationName)",
        ], shortTitle: "Find Items", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenItemIntent(), phrases: [
            "Open \(\.$item) in \(.applicationName)",
        ], shortTitle: "Open Item", systemImageName: "doc.text.magnifyingglass")
    }
}

