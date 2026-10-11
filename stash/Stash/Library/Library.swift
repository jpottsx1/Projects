import CoreData
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// What the sidebar is showing.
enum SidebarSelection: Hashable {
    case all
    case kind(ItemKind)
    case category(ItemCategory)
    case tag(Tag)
}

/// The library and the window's state. Every change to items goes through
/// here, so the search index, files on disk and links stay in step.
@MainActor
@Observable
final class Library {
    /// `[[Title]]` links become `stash://open?title=...` in the preview.
    nonisolated static let linkScheme = "stash"
    /// Bigger documents stay on the device they were added on: iCloud
    /// handles them poorly, and every device would have to download them.
    static let largestSyncedFile = 100 * 1024 * 1024

    let context: ModelContext
    let files: FileStore
    private let index: SearchIndex?

    var sidebar: SidebarSelection? = .all
    var selection: Item?
    var isAddingLink = false
    var isImporting = false
    var importError: String?

    private var query = ""
    /// What's typed in the search field. Searching happens as it changes.
    var searchText: String {
        get { query }
        set {
            query = newValue
            runSearch()
        }
    }
    /// Ids from the full-text index, best match first; nil when no words are being searched for.
    private(set) var searchHits: [UUID]?
    /// Goes up whenever something that links or backlinks depend on changes,
    /// so the views showing them redraw.
    private(set) var revision = 0

    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var shareObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// Set by `SHARE_EXTENSION` in Config/Stash.xcconfig.
    #if SHARE_EXTENSION
    static let sharingEnabled = true
    #else
    static let sharingEnabled = false
    #endif
    /// Where the share extension leaves things; nil when sharing is off.
    private let inbox: SharedInbox? = Library.sharingEnabled ? SharedInbox.forAppGroup() : nil

    init(context: ModelContext) {
        self.context = context
        let support = URL.applicationSupportDirectory.appendingPathComponent("Stash", isDirectory: true)
        files = FileStore(root: support.appendingPathComponent("Files", isDirectory: true))
        index = SearchIndex(url: support.appendingPathComponent("SearchIndex.sqlite"))
        refreshAfterStoreChange()
        importSharedItems()

        if inbox != nil {
            // The share extension signals as it saves, so something shared
            // while Stash is open appears straight away.
            ShareSignal.startListening()
            shareObserver = NotificationCenter.default.addObserver(
                forName: .stashSharedItemsArrived, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.importSharedItems() }
            }
        }

        guard SyncMonitor.isEnabled else { return }
        // Posted when changes arrive in the store from outside this
        // context -- in practice, from iCloud. The views update on their
        // own; the search index, merged tags and files need a hand.
        storeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    // MARK: - Adding

    @discardableResult
    func newNote(titled title: String = "") -> Item {
        let item = Item(kind: .note, title: title)
        insert(item)
        return item
    }

    func addLink(_ url: URL) {
        let item = Item(kind: .link, title: WebAddress.displayHost(of: url))
        item.urlString = url.absoluteString
        insert(item)
        Task { await refreshPage(of: item) }
    }

    func importFiles(_ urls: [URL]) {
        var last: Item?
        for url in urls {
            let item = Item(kind: .document, title: url.deletingPathExtension().lastPathComponent)
            do {
                item.storedFilePath = try files.importFile(at: url, for: item.uuid)
            } catch {
                importError = "“\(url.lastPathComponent)”: \(error.localizedDescription)"
                continue
            }
            item.contentTypeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier
            item.fileData = syncableContents(of: item)
            insert(item, select: false)
            last = item
            Task { await extractText(from: item) }
        }
        if let last { selection = last }
    }

    /// Whatever was dropped on the list: files are imported, web addresses saved as links.
    func add(_ urls: [URL]) {
        importFiles(urls.filter(\.isFileURL))
        for url in urls where !url.isFileURL {
            if let web = WebAddress.url(from: url.absoluteString) { addLink(web) }
        }
    }

    /// A new item lands where you're looking: in the selected category or
    /// tag, and visible in the list.
    private func insert(_ item: Item, select: Bool = true) {
        context.insert(item)
        switch sidebar {
        case .category(let category):
            item.category = category
        case .tag(let tag):
            item.tags = [tag]
        case .kind(let kind) where kind != item.kind:
            sidebar = .all
        default:
            break
        }
        if !query.isEmpty { searchText = "" }
        save()
        reindex(item)
        if select { selection = item }
    }

    // MARK: - Editing

    /// Call after any change to an item's content.
    func didEdit(_ item: Item) {
        item.modifiedAt = .now
        reindex(item)
    }

    /// Points `[[links]]` to an item's old title at its new one.
    func rename(_ item: Item, from oldTitle: String) {
        guard !oldTitle.isEmpty, WikiLinks.key(oldTitle) != WikiLinks.key(item.title) else { return }
        for note in notesLinking(toTitle: oldTitle) {
            note.body = WikiLinks.renaming(oldTitle, to: item.title, in: note.body)
            didEdit(note)
        }
        save()
    }

    func refreshPage(of item: Item) async {
        guard let url = item.url, let page = await TextExtractor.page(at: url), isAlive(item) else { return }
        // Only replace a title nobody has typed over.
        if let title = page.title, item.title.isEmpty || item.title == WebAddress.displayHost(of: url) {
            item.title = title
        }
        item.summary = page.summary ?? ""
        item.extractedText = page.text
        reindex(item)
        save()
    }

    func extractText(from item: Item) async {
        guard let url = localFile(for: item) else { return }
        let text = await TextExtractor.text(fromFileAt: url, type: item.contentType)
        guard isAlive(item), !text.isEmpty else { return }
        item.extractedText = text
        reindex(item)
        save()
    }

    /// The document's file on this device. One synced from another device
    /// is written out the first time it's asked for; nil until it has
    /// finished downloading from iCloud (or if it was too big to sync).
    func localFile(for item: Item) -> URL? {
        guard let path = item.storedFilePath else { return nil }
        if !files.exists(path), let data = item.fileData {
            try? files.write(data, to: path)
        }
        return files.exists(path) ? files.url(for: path) : nil
    }

    private func syncableContents(of item: Item) -> Data? {
        guard let path = item.storedFilePath else { return nil }
        let url = files.url(for: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= Self.largestSyncedFile else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func delete(_ items: [Item]) {
        for item in items {
            if selection == item { selection = nil }
            if let path = item.storedFilePath { files.remove(path) }
            index?.remove(item.uuid)
            context.delete(item)
        }
        save()
        revision += 1
        runSearch()
    }

    // MARK: - Tags

    /// Adds every tag in a comma-separated list, reusing tags that exist.
    func addTags(from text: String, to item: Item) {
        let names = TagName.split(text)
        guard !names.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        for name in names where !item.hasTag(key: TagName.key(name)) {
            let tag: Tag
            if let found = existing.first(where: { $0.key == TagName.key(name) }) {
                tag = found
            } else {
                tag = Tag(name: name)
                context.insert(tag)
            }
            item.tags = (item.tags ?? []) + [tag]
        }
        didEdit(item)
        save()
    }

    func removeTag(_ tag: Tag, from item: Item) {
        item.tags?.removeAll { $0 == tag }
        didEdit(item)
        save()
    }

    func delete(_ tag: Tag) {
        if sidebar == .tag(tag) { sidebar = .all }
        let tagged = tag.items ?? []
        context.delete(tag)
        save()
        tagged.forEach(reindex)
    }

    // MARK: - Categories

    @discardableResult
    func newCategory(named name: String, in parent: ItemCategory? = nil) -> ItemCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let category = ItemCategory(name: trimmed)
        context.insert(category)
        category.parent = parent
        save()
        publishCategories()
        return category
    }

    func rename(_ category: ItemCategory, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        category.name = trimmed
        save()
        publishCategories()
    }

    /// Categories inside it go too; the items in them are kept, uncategorized.
    func delete(_ category: ItemCategory) {
        if case .category(let shown) = sidebar, category.contains(shown) { sidebar = .all }
        context.delete(category)
        save()
        publishCategories()
    }

    /// The share extension can't open the library, so it chooses a category
    /// from a list the app writes out whenever categories change.
    private func publishCategories() {
        guard let inbox else { return }
        let all = (try? context.fetch(FetchDescriptor<ItemCategory>())) ?? []
        let tree = all.filter { $0.parent == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap(\.flattened)
        inbox.writeCategories(tree.map { SharedCategory(id: $0.uuid, path: $0.path) })
    }

    // MARK: - Shared from other apps

    /// Takes in whatever the share extension has left in the inbox. At
    /// launch, when the app comes to the front, and when the extension
    /// signals. Anything that can't be taken in yet stays for next time.
    func importSharedItems() {
        guard let inbox else { return }
        let waiting = inbox.pending()
        guard !waiting.isEmpty else { return }
        let categories = (try? context.fetch(FetchDescriptor<ItemCategory>())) ?? []

        for pending in waiting {
            let entry = pending.entry
            let item: Item
            switch entry.kind {
            case .link:
                guard let url = entry.url.flatMap(URL.init(string:)) else {
                    inbox.remove(pending)
                    continue
                }
                item = Item(kind: .link, title: entry.title.isEmpty ? WebAddress.displayHost(of: url) : entry.title)
                item.urlString = url.absoluteString
            case .note:
                item = Item(kind: .note, title: entry.title)
            case .file:
                guard let file = pending.file else {
                    inbox.remove(pending)
                    continue
                }
                item = Item(kind: .document, title: entry.title)
                guard let path = try? files.importFile(at: file, for: item.uuid) else { continue }
                item.storedFilePath = path
                item.contentTypeIdentifier = UTType(filenameExtension: file.pathExtension)?.identifier
                item.fileData = syncableContents(of: item)
            }
            item.body = entry.text
            item.createdAt = entry.createdAt
            item.modifiedAt = entry.createdAt
            context.insert(item)
            item.category = entry.categoryID.flatMap { id in categories.first { $0.uuid == id } }
            if !entry.tags.isEmpty { addTags(from: entry.tags.joined(separator: ","), to: item) }
            save()
            reindex(item)
            inbox.remove(pending)

            switch item.kind {
            case .link: Task { await refreshPage(of: item) }
            case .document: Task { await extractText(from: item) }
            case .note: break
            }
        }
    }

    // MARK: - Links between items

    func link(_ item: Item, to other: Item) {
        guard item != other, !(item.linksTo ?? []).contains(other) else { return }
        item.linksTo = (item.linksTo ?? []) + [other]
        save()
        revision += 1
    }

    /// Removes a hand-made link whichever way round it was made.
    func unlink(_ item: Item, _ other: Item) {
        item.linksTo?.removeAll { $0 == other }
        other.linksTo?.removeAll { $0 == item }
        save()
        revision += 1
    }

    /// The item a `[[Title]]` link points at, if there is one.
    func item(titled title: String) -> Item? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let key = WikiLinks.key(trimmed)
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.title.localizedStandardContains(trimmed) })
        return (try? context.fetch(descriptor))?.first { WikiLinks.key($0.title) == key }
    }

    /// Follows a link tapped in a note's preview, making the note if it doesn't exist yet.
    func open(wikiURL url: URL) {
        guard let title = WikiLinks.title(from: url, scheme: Self.linkScheme) else { return }
        if let target = item(titled: title) {
            selection = target
        } else {
            newNote(titled: title)
        }
    }

    /// Notes whose text has a `[[link]]` to `item`.
    func notesLinking(to item: Item) -> [Item] {
        _ = revision
        return notesLinking(toTitle: item.title).filter { $0 != item }
    }

    private func notesLinking(toTitle title: String) -> [Item] {
        let key = WikiLinks.key(title)
        guard !key.isEmpty else { return [] }
        return notes(mentioning: title).filter { note in
            WikiLinks.titles(in: note.body).contains { WikiLinks.key($0) == key }
        }
    }

    /// Notes whose text contains `title` as a phrase. The index narrows it
    /// down; without one, every note is checked.
    private func notes(mentioning title: String) -> [Item] {
        let note = ItemKind.note.rawValue
        if let index, let expression = SearchQuery.phrase(title, inColumn: "body") {
            let ids = index.search(expression)
            guard !ids.isEmpty else { return [] }
            let descriptor = FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.uuid) && $0.kindRaw == note })
            return (try? context.fetch(descriptor)) ?? []
        }
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.kindRaw == note })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Showing and searching

    var sidebarTitle: String {
        switch sidebar ?? .all {
        case .all: "All Items"
        case .kind(let kind): kind.pluralName
        case .category(let category): category.name
        case .tag(let tag): "#" + tag.name
        }
    }

    /// `items` narrowed to the sidebar selection and the search, best match
    /// first while searching.
    func visibleItems(from items: [Item]) -> [Item] {
        var result = items.filter(isInSidebar)
        let search = SearchQuery(query)
        if !search.tags.isEmpty {
            result = result.filter { item in search.tags.allSatisfy { item.hasTag(key: $0) } }
        }
        guard search.ftsExpression != nil else { return result }

        if let hits = searchHits {
            var rank: [UUID: Int] = [:]
            for (position, id) in hits.enumerated() where rank[id] == nil { rank[id] = position }
            return result
                .filter { rank[$0.uuid] != nil }
                .sorted { rank[$0.uuid, default: .max] < rank[$1.uuid, default: .max] }
        }

        // No index (it failed to open): a plain, unranked text match.
        let words = search.terms.map { term -> String in
            switch term {
            case .word(let text), .phrase(let text): return text
            }
        }
        return result.filter { item in
            words.allSatisfy { word in
                [item.title, item.body, item.summary, item.extractedText]
                    .contains { $0.localizedStandardContains(word) }
            }
        }
    }

    private func isInSidebar(_ item: Item) -> Bool {
        switch sidebar ?? .all {
        case .all: true
        case .kind(let kind): item.kind == kind
        case .category(let category): category.contains(item.category)
        case .tag(let tag): (item.tags ?? []).contains(tag)
        }
    }

    private func runSearch() {
        if let expression = SearchQuery(query).ftsExpression, let index {
            searchHits = index.search(expression)
        } else {
            searchHits = nil
        }
    }

    // MARK: - Changes from iCloud

    /// Changes tend to arrive in bursts; deal with each burst once.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.refreshAfterStoreChange()
        }
    }

    /// At launch, and after changes arrive from another device.
    private func refreshAfterStoreChange() {
        if let selection, !isAlive(selection) { self.selection = nil }
        mergeDuplicates()
        // Only tidy files away when the library definitely loaded: an empty
        // list from a failed fetch would otherwise delete every document.
        guard let items = try? context.fetch(FetchDescriptor<Item>()) else { return }
        index?.replaceAll(with: items.map(entry(for:)))
        files.removeFolders(notBelongingTo: Set(items.map(\.uuid)))
        publishCategories()
        revision += 1
        runSearch()
    }

    /// Two devices can each make a tag called "work", or a category called
    /// "Recipes", before they've seen each other's. Once both arrive they're
    /// folded into one. Every device keeps the copy with the lowest uuid,
    /// so devices doing this at the same time agree on which one survives.
    private func mergeDuplicates() {
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        for group in Dictionary(grouping: tags, by: \.key).values where group.count > 1 {
            let ordered = group.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                for item in duplicate.items ?? [] where !(item.tags ?? []).contains(keeper) {
                    item.tags = (item.tags ?? []) + [keeper]
                }
                if sidebar == .tag(duplicate) { sidebar = .tag(keeper) }
                context.delete(duplicate)
            }
        }

        let categories = (try? context.fetch(FetchDescriptor<ItemCategory>())) ?? []
        mergeDuplicates(among: categories.filter { $0.parent == nil })
        save()
    }

    /// Same-named categories side by side become one, holding the items and
    /// categories of both; then the same one level down.
    private func mergeDuplicates(among siblings: [ItemCategory]) {
        var survivors: [ItemCategory] = []
        for group in Dictionary(grouping: siblings, by: { $0.name.lowercased() }).values {
            let ordered = group.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                for item in duplicate.items ?? [] { item.category = keeper }
                let children = duplicate.children ?? []
                for child in children { child.parent = keeper }
                // Deleting a category deletes the ones inside it, so make
                // sure the moved ones are no longer counted as inside.
                duplicate.children = []
                if case .category(let shown) = sidebar, shown == duplicate { sidebar = .category(keeper) }
                context.delete(duplicate)
            }
            survivors.append(keeper)
        }
        for survivor in survivors {
            mergeDuplicates(among: survivor.children ?? [])
        }
    }

    // MARK: - Index

    func reindex(_ item: Item) {
        index?.update(entry(for: item))
        revision += 1
        if !query.isEmpty { runSearch() }
    }

    private func entry(for item: Item) -> SearchIndex.Entry {
        let fileName = item.storedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return SearchIndex.Entry(
            id: item.uuid,
            title: item.title,
            body: item.summary.isEmpty ? item.body : item.body + "\n" + item.summary,
            tags: item.sortedTags.map(\.name).joined(separator: " "),
            extra: [item.urlString ?? "", fileName, item.extractedText].joined(separator: "\n"))
    }

    // MARK: - Saving

    private func save() {
        try? context.save()
    }

    /// False once an item has been deleted -- checked after anything slow,
    /// like a download, before writing to it.
    private func isAlive(_ item: Item) -> Bool {
        item.modelContext != nil && !item.isDeleted
    }
}
