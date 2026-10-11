import CoreData
import CoreGraphics
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// What the sidebar is showing.
enum SidebarSelection: Hashable {
    case inbox
    case all
    case favorites
    /// Items with a reminder, soonest first.
    case reminders
    case kind(ItemKind)
    case category(ItemCategory)
    case tag(Tag)
    case smartFilter(SmartFilter)
    /// Pages saved more than once, and files imported more than once.
    case duplicates
    case trash
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
    /// How long items stay in the Trash before they go for good.
    static let trashDays = 30

    let context: ModelContext
    let files: FileStore
    private let index: SearchIndex?
    @ObservationIgnored private let spotlight = SpotlightIndex()

    var sidebar: SidebarSelection? = .all {
        didSet { if sidebar != oldValue { compileSmartFilter() } }
    }
    /// The one item the detail shows. Choosing one item, from anywhere,
    /// ends a selection of several.
    var selection: Item? {
        didSet {
            if selection != nil, !multiSelection.isEmpty { multiSelection = [] }
            // Looking at something reads it.
            if let selection, selection.isUnread, selection != oldValue {
                selection.isUnread = false
                save()
            }
        }
    }
    /// Two or more items chosen together, to change at once; empty otherwise.
    private(set) var multiSelection: Set<Item> = []
    /// Asking for tags to add to these.
    var taggingItems: [Item]?
    /// Choosing a reminder time for these.
    var remindingItems: [Item]?

    /// What the list shows as selected.
    var listSelection: Set<Item> {
        multiSelection.isEmpty ? Set([selection].compactMap { $0 }) : multiSelection
    }

    /// What menu commands act on: the items chosen together, or the one.
    var selectedItems: [Item] {
        multiSelection.isEmpty ? [selection].compactMap { $0 } : Array(multiSelection)
    }

    /// Takes items out of a selection of several -- they've gone to or
    /// from the Trash -- leaving one item shown if only one is left.
    private func deselect(_ items: [Item]) {
        guard !multiSelection.isEmpty else { return }
        select(multiSelection.subtracting(items))
    }

    /// Sets the selection from the list: one item shows it, several can
    /// be changed together.
    func select(_ items: Set<Item>) {
        if items.count > 1 {
            selection = nil
            multiSelection = items
        } else {
            multiSelection = []
            selection = items.first
        }
    }
    /// A highlight chosen in the side panel, for the reader to scroll to.
    var revealedHighlight: Highlight?
    /// The highlight whose note is being written.
    var editingHighlight: Highlight?
    var isAddingLink = false
    /// What's to be exported; the window does the exporting.
    var exportRequest: ExportRequest?
    var isRestoring = false
    var isEditingRules = false
    var isScanning = false
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
    /// What's typed in the search field, worked out.
    private(set) var search = CompiledSearch.none
    /// The smart filter the sidebar is showing, worked out.
    private var smartFilterSearch: CompiledSearch?

    var sort: ItemSort = ItemSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .modified {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    var sortAscending: Bool = UserDefaults.standard.bool(forKey: "sortAscending") {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
    }
    /// Rows or cards, where there's room for cards (not on an iPhone).
    var showsGrid: Bool = UserDefaults.standard.bool(forKey: "showsGrid") {
        didSet { UserDefaults.standard.set(showsGrid, forKey: "showsGrid") }
    }
    /// Goes up whenever something that links or backlinks depend on changes,
    /// so the views showing them redraw.
    private(set) var revision = 0

    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var shareObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    /// Documents Quick Look has been asked for a thumbnail of this session,
    /// so files it can't picture aren't asked about after every sync.
    @ObservationIgnored private var thumbnailsTried: Set<UUID> = []
    /// Items that arrived this session and haven't been read yet: rules run
    /// on them again once their page or document text is in.
    @ObservationIgnored private var awaitingRules: Set<UUID> = []

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
    func newNote(titled title: String = "", text: String = "") -> Item {
        let item = Item(kind: .note, title: title)
        item.body = text
        insert(item)
        return item
    }

    @discardableResult
    func addLink(_ url: URL) -> Item {
        let item = Item(kind: .link, title: WebAddress.displayHost(of: url))
        item.urlString = url.absoluteString
        item.isUnread = true
        insert(item)
        arrived(item)
        Task { await refreshPage(of: item) }
        return item
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
            item.isUnread = true
            insert(item, select: false)
            arrived(item)
            last = item
            Task {
                await fillContentHash(of: item)
                await fillThumbnail(of: item)
                await extractText(from: item)
            }
        }
        if let last { selection = last }
    }

    /// Pages from the document camera, as one searchable PDF.
    func addScan(_ pages: [CGImage]) async {
        guard !pages.isEmpty, let pdf = await ScannedPDF.make(pages: pages) else {
            importError = "The scan couldn’t be made into a PDF."
            return
        }
        let name = "Scan " + Date.now.formatted(.dateTime.year().month().day().hour().minute())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name + ".pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try pdf.write(to: file)
        } catch {
            importError = error.localizedDescription
            return
        }
        importFiles([file])
        try? FileManager.default.removeItem(at: folder)
    }

    /// Things handed over by another device: on a Mac, *File › Import from
    /// iPhone or iPad* (Continuity Camera) gives a scanned PDF or a photo.
    func importProviders(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard let type = [UTType.pdf, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
                continue
            }
            let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let copied: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    // The file is gone once this returns, so copy it now.
                    guard let url else { return continuation.resume(returning: nil) }
                    let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                    let name = type == .pdf ? "Scan" : "Photo"
                    let destination = folder.appendingPathComponent(name).appendingPathExtension(ext)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let copied {
                importFiles([copied])
                try? FileManager.default.removeItem(at: folder)
            }
        }
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
        case .favorites:
            item.isFavorite = true
        case .kind(let kind) where kind != item.kind:
            sidebar = .all
        case .smartFilter, .duplicates, .trash:
            sidebar = .all
        default:
            break
        }
        // Pages and files arriving with nowhere to go wait in the Inbox;
        // notes written here don't need filing.
        if item.category == nil, item.kind != .note || sidebar == .inbox {
            item.inInbox = true
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

    /// Fetches a link's title, summary and text, then saves a full copy of
    /// the page. Each step stands alone: a page whose HTML can't be read
    /// can often still be copied, and the other way round.
    func refreshPage(of item: Item) async {
        if let url = item.url, let page = await TextExtractor.page(at: url), isAlive(item) {
            if let title = page.title, !Self.hasOwnTitle(item, url: url) {
                item.title = title
            }
            item.summary = page.summary ?? ""
            item.extractedText = page.text
            reindex(item)
            save()
        }
        guard isAlive(item) else { return }
        await savePageCopy(of: item)
        finishedReading(item)
    }

    /// Links whose page is being copied right now, for the views to show it.
    private(set) var copyingPages: Set<UUID> = []

    func savePageCopy(of item: Item) async {
        guard let url = item.url, !copyingPages.contains(item.uuid) else { return }
        copyingPages.insert(item.uuid)
        defer { copyingPages.remove(item.uuid) }

        guard let page = await PageArchiver.archive(url), isAlive(item) else { return }
        let path = "\(item.uuid.uuidString)/Page.webarchive"
        do {
            try files.write(page.archive, to: path)
        } catch {
            return
        }
        item.archivePath = path
        item.archivedAt = .now
        item.archiveData = page.archive.count <= Self.largestSyncedFile ? page.archive : nil
        // A page that no longer has an article keeps the one it had.
        if let article = page.article { item.article = article }
        if let thumbnail = page.thumbnail { item.thumbnailData = thumbnail }
        if let title = page.title, !title.isEmpty, !Self.hasOwnTitle(item, url: url) {
            item.title = title
        }
        // The page as shown can hold far more text than its HTML did.
        if page.text.count > item.extractedText.count {
            item.extractedText = String(page.text.prefix(TextExtractor.maxLength))
        }
        reindex(item)
        save()
    }

    /// The saved copy on this device, written out from iCloud the first
    /// time it's asked for, as with `localFile(for:)`.
    func localPageCopy(for item: Item) -> URL? {
        guard let path = item.archivePath else { return nil }
        if !files.exists(path), let data = item.archiveData {
            try? files.write(data, to: path)
        }
        return files.exists(path) ? files.url(for: path) : nil
    }

    /// Whether someone has typed a title over the one a link started with
    /// (its site's name), which a fetched title mustn't replace.
    private static func hasOwnTitle(_ item: Item, url: URL) -> Bool {
        !item.title.isEmpty && item.title != WebAddress.displayHost(of: url)
    }

    func extractText(from item: Item) async {
        guard let url = localFile(for: item) else { return }
        let text = await TextExtractor.text(fromFileAt: url, type: item.contentType)
        guard isAlive(item) else { return }
        if !text.isEmpty {
            item.extractedText = text
            reindex(item)
            save()
        }
        finishedReading(item)
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

    func syncableContents(of item: Item) -> Data? {
        guard let path = item.storedFilePath else { return nil }
        let url = files.url(for: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= Self.largestSyncedFile else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    // MARK: - Marking

    func setUnread(_ items: [Item], _ unread: Bool) {
        for item in items { item.isUnread = unread }
        save()
        runSearch()
    }

    /// Sets (or, with nil, clears) a reminder on each item.
    func setReminder(_ items: [Item], at date: Date?) {
        for item in items {
            item.remindAt = date
            Reminders.shared.schedule(item)
        }
        save()
        runSearch()
        if date != nil { Task { await Reminders.shared.requestPermission() } }
    }

    func setLabel(_ items: [Item], _ label: ItemLabel) {
        for item in items { item.label = label }
        save()
        runSearch()
    }

    func setRating(_ items: [Item], _ rating: Int) {
        for item in items { item.rating = max(0, min(5, rating)) }
        save()
        runSearch()
    }

    /// Files items in a category, which takes them out of the Inbox.
    func file(_ items: [Item], in category: ItemCategory?) {
        for item in items {
            item.category = category
            item.inInbox = false
            reindex(item)
        }
        save()
        runSearch()
    }

    /// Takes items out of the Inbox where they are.
    func markFiled(_ items: [Item]) {
        for item in items { item.inInbox = false }
        save()
        runSearch()
    }

    /// After the side panel changes an item's category itself.
    func didChangeCategory(of item: Item) {
        if item.category != nil { item.inInbox = false }
        didEdit(item)
        save()
    }

    /// Something that came from outside the app, through Shortcuts: new,
    /// and waiting to be filed.
    func markReceived(_ item: Item) {
        item.isUnread = true
        if item.category == nil { item.inInbox = true }
        save()
        arrived(item)
        runSearch()
    }

    // MARK: - Quick capture

    /// A note jotted from the menu bar: it goes to the Inbox, without
    /// changing what the window is showing.
    @discardableResult
    func captureNote(title: String, text: String) -> Item {
        let item = Item(kind: .note, title: title)
        item.body = text
        context.insert(item)
        save()
        reindex(item)
        markReceived(item)
        return item
    }

    /// A link saved from the menu bar or a quick action, likewise.
    @discardableResult
    func captureLink(_ url: URL) -> Item {
        let item = Item(kind: .link, title: WebAddress.displayHost(of: url))
        item.urlString = url.absoluteString
        context.insert(item)
        save()
        reindex(item)
        markReceived(item)
        Task { await refreshPage(of: item) }
        return item
    }

    // MARK: - Smart rules

    /// Runs the rules on something that has just come in.
    private func arrived(_ item: Item) {
        awaitingRules.insert(item.uuid)
        applyRules(to: item)
    }

    /// Runs the rules again on an item that arrived this session, now its
    /// page or document has been read.
    private func finishedReading(_ item: Item) {
        guard awaitingRules.remove(item.uuid) != nil, isAlive(item) else { return }
        applyRules(to: item)
    }

    private func enabledRules() -> [SmartRule] {
        let rules = (try? context.fetch(FetchDescriptor<SmartRule>(predicate: #Predicate { $0.isEnabled }))) ?? []
        return rules.sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
    }

    private func applyRules(to item: Item) {
        guard !item.isTrashed else { return }
        for rule in enabledRules() where CompiledSearch(SearchQuery(rule.query), index: index).matches(item) {
            apply(rule, to: item)
        }
    }

    /// Runs one rule over everything already in the library that matches
    /// it, and says how many that was.
    @discardableResult
    func apply(_ rule: SmartRule, toExisting: Bool) -> Int {
        let search = CompiledSearch(SearchQuery(rule.query), index: index)
        let items = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).filter { !$0.isTrashed && search.matches($0) }
        for item in items { apply(rule, to: item) }
        save()
        runSearch()
        return items.count
    }

    private func apply(_ rule: SmartRule, to item: Item) {
        if let category = rule.category {
            item.category = category
            item.inInbox = false
        }
        if !rule.tagsToAdd.trimmingCharacters(in: .whitespaces).isEmpty {
            addTags(from: rule.tagsToAdd, to: item)
        }
        if rule.labelRaw >= 0, let label = ItemLabel(rawValue: rule.labelRaw) { item.label = label }
        if rule.rating >= 0 { item.rating = min(rule.rating, 5) }
        if rule.makesFavorite { item.isFavorite = true }
        if rule.marksRead { item.isUnread = false }
        if rule.takesOutOfInbox { item.inInbox = false }
        reindex(item)
        save()
    }

    @discardableResult
    func newRule() -> SmartRule {
        let rule = SmartRule(name: "New Rule")
        context.insert(rule)
        save()
        return rule
    }

    func delete(_ rule: SmartRule) {
        context.delete(rule)
        save()
    }

    // MARK: - Highlights

    @discardableResult
    func addHighlight(to item: Item, text: String, anchor: HighlightAnchor, position: Double,
                      color: HighlightColor = .yellow) -> Highlight {
        let highlight = Highlight(text: text, anchor: anchor, position: position, color: color)
        context.insert(highlight)
        highlight.item = item
        didEdit(item)
        save()
        return highlight
    }

    func update(_ highlight: Highlight, note: String? = nil, color: HighlightColor? = nil) {
        if let note { highlight.note = note }
        if let color { highlight.color = color }
        if let item = highlight.item { didEdit(item) }
        save()
    }

    func delete(_ highlight: Highlight) {
        let item = highlight.item
        if revealedHighlight == highlight { revealedHighlight = nil }
        if editingHighlight == highlight { editingHighlight = nil }
        context.delete(highlight)
        save()
        if let item { didEdit(item) }
    }

    // MARK: - Favourites and the Trash

    func setFavorite(_ items: [Item], _ favorite: Bool) {
        for item in items { item.isFavorite = favorite }
        save()
        runSearch()
    }

    /// Items in the Trash keep everything -- files, tags, links -- until
    /// they're deleted for good, by hand or after `trashDays`.
    func moveToTrash(_ items: [Item]) {
        deselect(items)
        for item in items where !item.isTrashed {
            if selection == item { selection = nil }
            item.trashedAt = .now
            spotlight.update(item)
        }
        Reminders.shared.cancel(items)
        save()
        revision += 1
        runSearch()
    }

    func restore(_ items: [Item]) {
        deselect(items)
        for item in items {
            item.trashedAt = nil
            spotlight.update(item)
            Reminders.shared.schedule(item)
        }
        save()
        revision += 1
        runSearch()
    }

    func deleteImmediately(_ items: [Item]) {
        deselect(items)
        for item in items {
            if selection == item { selection = nil }
            if let path = item.storedFilePath ?? item.archivePath { files.remove(path) }
            index?.remove(item.uuid)
            context.delete(item)
        }
        spotlight.remove(items.map(\.uuid))
        Reminders.shared.cancel(items)
        save()
        revision += 1
        runSearch()
    }

    func emptyTrash() {
        let trashed = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt != nil }))) ?? []
        deleteImmediately(trashed)
    }

    /// Every device does this, and they all agree on what's old enough.
    private func deleteOldTrash() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.trashDays, to: .now) else { return }
        let trashed = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt != nil }))) ?? []
        let old = trashed.filter { ($0.trashedAt ?? .now) < cutoff }
        if !old.isEmpty { deleteImmediately(old) }
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

    func addTags(from text: String, to items: [Item]) {
        for item in items { addTags(from: text, to: item) }
        runSearch()
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
    func publishCategories() {
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
            item.isUnread = true
            context.insert(item)
            item.category = entry.categoryID.flatMap { id in categories.first { $0.uuid == id } }
            item.inInbox = item.category == nil
            if !entry.tags.isEmpty { addTags(from: entry.tags.joined(separator: ","), to: item) }
            save()
            reindex(item)
            arrived(item)
            inbox.remove(pending)

            switch item.kind {
            case .link: Task { await refreshPage(of: item) }
            case .document:
                Task {
                    await fillContentHash(of: item)
                    await fillThumbnail(of: item)
                    await extractText(from: item)
                }
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
        let named = ((try? context.fetch(descriptor)) ?? []).filter { WikiLinks.key($0.title) == key }
        // One in the Trash is only the answer when there's nothing else.
        return named.first { !$0.isTrashed } ?? named.first
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
        return notesLinking(toTitle: item.title).filter { $0 != item && !$0.isTrashed }
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
        case .inbox: "Inbox"
        case .all: "All Items"
        case .favorites: "Favorites"
        case .reminders: "Reminders"
        case .kind(let kind): kind.pluralName
        case .category(let category): category.name
        case .tag(let tag): "#" + tag.name
        case .smartFilter(let filter): filter.name
        case .duplicates: "Duplicates"
        case .trash: "Trash"
        }
    }

    /// `items` narrowed to the sidebar selection and the search: best match
    /// first while searching by word, otherwise in the chosen order.
    func visibleItems(from items: [Item]) -> [Item] {
        if sidebar == .duplicates { return duplicates(among: items).flatMap { $0 } }
        var result = items.filter(isInSidebar)
        if !search.isEmpty { result = result.filter(search.matches) }
        if search.isRanked { return search.rank(result) }
        if sidebar == .reminders {
            return result.sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
        }
        return sort.sorted(result, ascending: sortAscending)
    }

    private func isInSidebar(_ item: Item) -> Bool {
        let selection = sidebar ?? .all
        if selection == .trash { return item.isTrashed }
        guard !item.isTrashed else { return false }
        switch selection {
        case .all, .trash, .duplicates: return true
        case .inbox: return item.inInbox
        case .favorites: return item.isFavorite
        case .reminders: return item.remindAt != nil
        case .kind(let kind): return item.kind == kind
        case .category(let category): return category.contains(item.category)
        case .tag(let tag): return (item.tags ?? []).contains(tag)
        case .smartFilter: return smartFilterSearch?.matches(item) ?? true
        }
    }

    /// Items saved more than once, grouped, each group oldest first.
    func duplicates(among items: [Item]) -> [[Item]] {
        let keyed = items.filter { !$0.isTrashed && $0.duplicateKey != nil }
        return Dictionary(grouping: keyed) { $0.duplicateKey! }.values
            .filter { $0.count > 1 }
            .map { $0.sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) } }
            .sorted { $0[0].displayTitle.localizedStandardCompare($1[0].displayTitle) == .orderedAscending }
    }

    /// Other copies of the same page or file.
    func duplicates(of item: Item) -> [Item] {
        _ = revision
        guard let key = item.duplicateKey else { return [] }
        let kind = item.kindRaw
        let sameKind = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        return sameKind.filter { $0 != item && !$0.isTrashed && $0.duplicateKey == key }
    }

    private func runSearch() {
        search = CompiledSearch(SearchQuery(query), index: index)
        compileSmartFilter()
    }

    private func compileSmartFilter() {
        if case .smartFilter(let filter) = sidebar {
            smartFilterSearch = CompiledSearch(SearchQuery(filter.query), index: index)
        } else {
            smartFilterSearch = nil
        }
    }

    // MARK: - Smart filters

    @discardableResult
    func newSmartFilter(named name: String, query: String) -> SmartFilter? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let filter = SmartFilter(name: trimmed, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(filter)
        save()
        return filter
    }

    func update(_ filter: SmartFilter, name: String, query: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { filter.name = trimmed }
        filter.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        compileSmartFilter()
    }

    func delete(_ filter: SmartFilter) {
        if sidebar == .smartFilter(filter) { sidebar = .all }
        context.delete(filter)
        save()
    }

    // MARK: - See Also

    /// Items most like this one: those sharing the words that say most
    /// about it, best first. Uses the index, so nothing without one.
    func related(to item: Item, limit: Int = 8) -> [Item] {
        guard let index else { return [] }
        let tags = item.sortedTags.map(\.name).joined(separator: " ")
        // The title and tags say most about what it is.
        let text = [item.title, item.title, item.title, tags, tags, item.body, item.summary, item.extractedText]
            .joined(separator: "\n")
        let words = Keywords.best(
            Keywords.counts(in: text),
            documentFrequency: { word in SearchQuery.anyWord([word]).map { index.count(matching: $0) } ?? 0 },
            documentCount: index.count())
        guard let expression = SearchQuery.anyWord(words) else { return [] }
        let ids = index.search(expression, limit: limit * 3).filter { $0 != item.uuid }
        guard !ids.isEmpty else { return [] }
        let found = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.uuid) }))) ?? []
        let byID = Dictionary(found.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { !$0.isTrashed }.prefix(limit).map { $0 }
    }

    // MARK: - Shortcuts and Spotlight

    func items(withIDs ids: [UUID]) -> [Item] {
        let found = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.uuid) }))) ?? []
        let byID = Dictionary(found.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Items matching search text, as typed in the search field, best first.
    func find(_ text: String, limit: Int = 50) -> [Item] {
        let compiled = CompiledSearch(SearchQuery(text), index: index)
        let all = (try? context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        return Array(compiled.rank(all.filter { !$0.isTrashed && compiled.matches($0) }).prefix(limit))
    }

    /// Shows an item opened from Spotlight or Shortcuts.
    func show(_ item: Item) {
        if item.isTrashed {
            sidebar = .trash
        } else if !isInSidebar(item) {
            sidebar = .all
        }
        if !query.isEmpty { searchText = "" }
        selection = item
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
    func refreshAfterStoreChange() {
        if let selection, !isAlive(selection) { self.selection = nil }
        mergeDuplicates()
        deleteOldTrash()
        // Only tidy files away when the library definitely loaded: an empty
        // list from a failed fetch would otherwise delete every document.
        guard let items = try? context.fetch(FetchDescriptor<Item>()) else { return }
        index?.replaceAll(with: items.map(entry(for:)))
        spotlight.replaceAll(with: items)
        Reminders.shared.replaceAll(with: items)
        files.removeFolders(notBelongingTo: Set(items.map(\.uuid)))
        // Documents added before duplicates were looked for, or whose
        // hash hasn't arrived from iCloud yet.
        let unfinished = items.filter { item in
            item.kind == .document && (item.contentHash.isEmpty || item.thumbnailData == nil)
                && item.storedFilePath.map(files.exists) == true
        }
        if !unfinished.isEmpty {
            // One at a time: there may be hundreds, and Quick Look is slow.
            Task {
                for item in unfinished {
                    await fillContentHash(of: item)
                    await fillThumbnail(of: item)
                }
            }
        }
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
                for rule in duplicate.rules ?? [] { rule.category = keeper }
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
        spotlight.update(item)
        revision += 1
        if !query.isEmpty { runSearch() }
    }

    private func entry(for item: Item) -> SearchIndex.Entry {
        let fileName = item.storedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let highlights = item.sortedHighlights
        // Highlights and their notes are your own words about it, so they
        // count with the body; the rest of the document's text counts least.
        let body = ([item.body, item.summary] + highlights.flatMap { [$0.text, $0.note] })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return SearchIndex.Entry(
            id: item.uuid,
            title: item.title,
            body: body,
            tags: item.sortedTags.map(\.name).joined(separator: " "),
            extra: [item.urlString ?? "", fileName, item.extractedText].joined(separator: "\n"))
    }

    /// Makes a document's thumbnail, if it hasn't one yet.
    func fillThumbnail(of item: Item) async {
        guard item.kind == .document, item.thumbnailData == nil, thumbnailsTried.insert(item.uuid).inserted,
              let path = item.storedFilePath, files.exists(path) else { return }
        guard let data = await Thumbnails.make(forFileAt: files.url(for: path)), isAlive(item) else { return }
        item.thumbnailData = data
        save()
    }

    /// Works out a document's hash, for finding duplicates, if it hasn't been yet.
    func fillContentHash(of item: Item) async {
        guard item.kind == .document, item.contentHash.isEmpty,
              let path = item.storedFilePath, files.exists(path) else { return }
        let url = files.url(for: path)
        let hash = await Task.detached(priority: .utility) { FileStore.sha256(of: url) }.value
        guard let hash, isAlive(item) else { return }
        item.contentHash = hash
        save()
        revision += 1
    }

    // MARK: - Saving

    func save() {
        try? context.save()
    }

    /// False once an item has been deleted -- checked after anything slow,
    /// like a download, before writing to it.
    private func isAlive(_ item: Item) -> Bool {
        item.modelContext != nil && !item.isDeleted
    }
}
