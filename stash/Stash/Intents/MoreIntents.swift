import AppIntents
import Foundation
import StashCore

/// Shortcuts and Siri for what came after the first actions: today's note,
/// voice notes, the reading queue, lists, your own fields, feeds and Ask
/// Your Library.

// MARK: - Entities

struct ListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stash List"
    static let defaultQuery = ListEntityQuery()

    let id: UUID
    @Property(title: "Name") var name: String

    @MainActor
    init(_ list: ItemList) {
        id = list.uuid
        name = list.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ListEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ListEntity] {
        StashStore.shared.library.itemLists().filter { identifiers.contains($0.uuid) }.map(ListEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ListEntity] {
        StashStore.shared.library.itemLists().filter { $0.name.localizedStandardContains(string) }.map(ListEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ListEntity] {
        StashStore.shared.library.itemLists().map(ListEntity.init)
    }
}

struct FieldEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stash Field"
    static let defaultQuery = FieldEntityQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: String

    @MainActor
    init(_ field: FieldDefinition) {
        id = field.uuid
        name = field.name
        kind = field.kind.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(kind)") }
}

struct FieldEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FieldEntity] {
        StashStore.shared.library.fieldDefinitions().filter { identifiers.contains($0.uuid) }.map(FieldEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FieldEntity] {
        StashStore.shared.library.fieldDefinitions().map(FieldEntity.init)
    }
}

struct FeedEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stash Feed"
    static let defaultQuery = FeedEntityQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Address") var url: URL?

    @MainActor
    init(_ feed: Feed) {
        id = feed.uuid
        title = feed.title
        url = feed.url
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct FeedEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FeedEntity] {
        StashStore.shared.library.feeds().filter { identifiers.contains($0.uuid) }.map(FeedEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FeedEntity] {
        StashStore.shared.library.feeds().map(FeedEntity.init)
    }
}

/// The library items for some entities, in order, leaving out any gone.
@MainActor
private func items(_ entities: [ItemEntity]) -> [Item] {
    StashStore.shared.library.items(withIDs: entities.map(\.id))
}

// MARK: - Daily notes

struct OpenTodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today’s Note"
    static let description = IntentDescription("Opens the day’s note in Stash, making it the first time.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> {
        .result(value: ItemEntity(StashStore.shared.library.openToday()))
    }
}

struct AddToTodaysNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Today’s Note"
    static let description = IntentDescription("Adds text to the end of the day’s note, without opening Stash.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "As a List Item", default: false) var asListItem: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to today’s note") { \.$asListItem }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> {
        let library = StashStore.shared.library
        let note = library.openToday()
        let line = asListItem ? "- " + text : text
        note.body = note.body.isEmpty ? line : note.body.trimmingCharacters(in: .newlines) + (asListItem ? "\n" : "\n\n") + line
        library.didEdit(note)
        library.save()
        return .result(value: ItemEntity(note))
    }
}

// MARK: - Voice notes

struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note"
    static let description = IntentDescription("Opens Stash and starts recording a voice note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        StashStore.shared.library.isRecording = true
        return .result()
    }
}

// MARK: - Reading queue and lists

struct ReadLaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Later"
    static let description = IntentDescription("Adds items to the Read Later queue, or saves a web page there.")

    @Parameter(title: "Items") var items: [ItemEntity]?
    @Parameter(title: "Web Address") var url: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$items) later") { \.$url }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        let library = StashStore.shared.library
        var chosen = Stash.items(items ?? [])
        if let url, let web = WebAddress.url(from: url.absoluteString) {
            let link = library.addLink(web)
            library.markReceived(link)
            chosen.append(link)
        }
        guard !chosen.isEmpty else { throw $items.needsValueError("What should be read later?") }
        library.setReadLater(chosen, true)
        return .result(value: chosen.map(ItemEntity.init))
    }
}

struct GetReadingQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Read Later Queue"
    static let description = IntentDescription("The items waiting to be read, oldest first, leaving out finished ones.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        let queue = StashStore.shared.library.find("is:readlater", limit: 200)
            .filter { $0.readingProgress < 0.98 }
            .sorted { ($0.readLaterAt ?? .distantPast) < ($1.readLaterAt ?? .distantPast) }
        return .result(value: queue.map(ItemEntity.init))
    }
}

struct AddToListIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to List"
    static let description = IntentDescription("Puts items in one of your lists, at the end.")

    @Parameter(title: "Items") var items: [ItemEntity]
    @Parameter(title: "List") var list: ListEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$items) to \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = StashStore.shared.library
        guard let target = library.itemLists().first(where: { $0.uuid == list.id }) else {
            throw $list.needsValueError("That list isn’t there any more. Which list?")
        }
        library.add(Stash.items(items), to: target)
        return .result()
    }
}

struct GetListItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Items in List"
    static let description = IntentDescription("A list’s items, in the list’s order.")

    @Parameter(title: "List") var list: ListEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the items in \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        let library = StashStore.shared.library
        let found = library.itemLists().first { $0.uuid == list.id }
        return .result(value: (found?.orderedItems ?? []).filter { !$0.isTrashed }.map(ItemEntity.init))
    }
}

// MARK: - Fields

struct SetFieldIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Field"
    static let description = IntentDescription("""
        Sets one of your own fields on items. Dates are written 2026-10-12, \
        yes-or-no fields take yes or no, and an empty value clears the field.
        """)

    @Parameter(title: "Field") var field: FieldEntity
    @Parameter(title: "Value") var value: String
    @Parameter(title: "Items") var items: [ItemEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$field) to \(\.$value) on \(\.$items)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = StashStore.shared.library
        guard let definition = library.fieldDefinitions().first(where: { $0.uuid == field.id }) else {
            throw $field.needsValueError("That field isn’t there any more. Which field?")
        }
        var stored = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if definition.kind == .yesNo, !stored.isEmpty {
            stored = ["yes", "true", "y", "1", "on"].contains(stored.lowercased()) ? "true" : "false"
        }
        library.setValue(stored, of: definition, for: Stash.items(items))
        return .result()
    }
}

struct GetFieldIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Field"
    static let description = IntentDescription("The value of one of your own fields on an item.")

    @Parameter(title: "Field") var field: FieldEntity
    @Parameter(title: "Item") var item: ItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$field) of \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let library = StashStore.shared.library
        guard let definition = library.fieldDefinitions().first(where: { $0.uuid == field.id }),
              let found = library.items(withIDs: [item.id]).first else { return .result(value: "") }
        return .result(value: library.value(of: definition, for: found))
    }
}

// MARK: - Feeds

struct SubscribeToFeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Subscribe to Feed"
    static let description = IntentDescription("Subscribes to a site’s feed (RSS, Atom or JSON Feed), given the feed’s address or the site’s.")

    @Parameter(title: "Address") var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Subscribe to \(\.$url)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FeedEntity> {
        let feed = try await StashStore.shared.library.subscribe(to: url.absoluteString)
        return .result(value: FeedEntity(feed))
    }
}

struct CheckFeedsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Feeds"
    static let description = IntentDescription("Checks feeds for new posts now, and gives the posts that arrived.")

    @Parameter(title: "Feed") var feed: FeedEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$feed) for new posts")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        let library = StashStore.shared.library
        let feeds = library.feeds().filter { feed == nil || $0.uuid == feed?.id }
        let before = Set(feeds.flatMap { $0.items ?? [] }.map(\.uuid))
        for each in feeds { await library.check(each) }
        let arrived = feeds.flatMap { $0.items ?? [] }.filter { !before.contains($0.uuid) }
        return .result(value: arrived.map(ItemEntity.init))
    }
}

// MARK: - Asking

struct AskLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Library"
    static let description = IntentDescription("""
        Answers a question from what’s in Stash, on this device, with Apple \
        Intelligence. Gives the answer, and the items it came from.
        """)

    @Parameter(title: "Question") var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Stash \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard Assistant.status == .available else {
            throw AskFailure.unavailable
        }
        let answer = await StashStore.shared.library.ask(question)
        if let error = answer.error { throw AskFailure.failed(error) }
        let text = answer.answer ?? ""
        let sources = (answer.cited.isEmpty ? Array(answer.sources.indices) : answer.cited.map { $0 - 1 })
            .filter { answer.sources.indices.contains($0) }
            .map { "[\($0 + 1)] " + answer.sources[$0].displayTitle }
        let full = sources.isEmpty ? text : text + "\n\n" + sources.joined(separator: "\n")
        return .result(value: full, dialog: IntentDialog(stringLiteral: text))
    }

    enum AskFailure: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "Asking your library needs Apple Intelligence, on iOS or macOS 26."
            case .failed(let reason): reason
            }
        }
    }
}
