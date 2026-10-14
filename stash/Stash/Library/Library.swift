import CoreData
import WidgetKit
#if os(macOS)
import AppKit
#endif
import LocalAuthentication
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// The counts beside the sidebar's places.
struct SidebarCounts: Equatable {
    var inbox = 0
    var due = 0
    var readLater = 0
    var duplicates = 0
}

/// What the sidebar is showing.
enum SidebarSelection: Hashable {
    case inbox
    case all
    case favorites
    /// What was added, looked at or changed lately.
    case recents
    /// Items in no category.
    case unfiled
    /// Items with a reminder, soonest first.
    case reminders
    case kind(ItemKind)
    case category(ItemCategory)
    case tag(Tag)
    case smartFilter(SmartFilter)
    /// Pages saved more than once, and files imported more than once.
    case duplicates
    case trash
    /// Notes to make other notes from.
    case templates
    /// A web feed's posts.
    case feed(Feed)
    /// Items put in a list by hand, in its order.
    case list(ItemList)
    /// Things saved to read, oldest first.
    case readLater
    /// What was added and changed, day by day.
    case timeline
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
    let index: SearchIndex?
    @ObservationIgnored private let spotlight: SpotlightIndex
    /// The library that syncs, and the only one in Spotlight, notifications,
    /// widgets and the share inbox, which can't tell libraries apart.
    let isMain: Bool
    /// Where its files, search index and so on are kept.
    let supportFolder: URL
    /// Reminders' notifications, for the main library only.
    private var reminders: Reminders? { isMain ? Reminders.shared : nil }

    /// Tag names the list is narrowed to, as Keep It's tag filter (see TagFilterBar).
    var tagFilter: [String] = []
    var isShowingTagFilter = false
    /// What *Recents* goes by, and how far back.
    var recentsKind: Recents.Kind = .all
    var recentsDays = 14

    var sidebar: SidebarSelection? = .all {
        didSet { if sidebar != oldValue { compileSmartFilter() } }
    }
    /// The one item the detail shows. Choosing one item, from anywhere,
    /// ends a selection of several.
    var selection: Item? {
        didSet {
            if selection != nil, !multiSelection.isEmpty { multiSelection = [] }
            remember(from: oldValue)
            // Looking at something reads it.
            if let selection, selection != oldValue {
                let viewedLately = selection.lastViewedAt.map { Date.now.timeIntervalSince($0) < 60 } ?? false
                if selection.isUnread || !viewedLately {
                    selection.isUnread = false
                    selection.lastViewedAt = .now
                    save()
                }
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
    /// Items to print, or to save as PDF; the window does it.
    var printRequest: Item?
    var pdfRequest: Item?
    var isScanning = false
    var isImporting = false
    var isImportingEvernote = false
    var isImportingNotesFolder = false
    var isChoosingFolderToIndex = false
    var isManagingIndexedFolders = false
    var isAddingFeed = false
    var importError: String?
    /// Said after an image with no web address is copied for searching.
    var imageSearchNotice: String?

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
    /// Rows, cards or columns; cards and columns where there's room (not on an iPhone).
    var layout: ItemLayout = ItemLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "showsGrid") ? .grid : .list) {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
    }
    /// Goes up whenever something that links or backlinks depend on changes,
    /// so the views showing them redraw.
    var revision = 0

    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var shareObserver: NSObjectProtocol?
    @ObservationIgnored var finderObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    /// Documents Quick Look has been asked for a thumbnail of this session,
    /// so files it can't picture aren't asked about after every sync.
    @ObservationIgnored private var thumbnailsTried: Set<UUID> = []
    /// Items that arrived this session and haven't been read yet: rules run
    /// on them again once their page or document text is in.
    @ObservationIgnored private var awaitingRules: Set<UUID> = []
    /// Feeds being checked right now, for the sidebar to show it.
    var checkingFeeds: Set<UUID> = []
    /// Checks feeds every so often while Stash is open.
    @ObservationIgnored var feedTimer: Task<Void, Never>?
    /// Runs scheduled smart rules while the library is open.
    @ObservationIgnored var ruleTimer: Task<Void, Never>?
    /// Where things dropped on the Sorter go, overriding the sidebar while they're added.
    @ObservationIgnored var arrivalTarget: ArrivalTarget?
    /// Every item's names, for automatic links, kept until the next save.
    @ObservationIgnored var autoLinkCache: (version: Int, names: [AutoLink.Name])?
    /// Indexed folders open this session, by the folder's uuid, and what's
    /// watching them for changes.
    @ObservationIgnored var indexedFolderURLs: [UUID: URL] = [:]
    @ObservationIgnored var folderWatchers: [UUID: FolderWatcher] = [:]
    /// Folders being read right now, for the views to show it.
    var scanningFolders: Set<UUID> = []
    /// Recordings being turned into text, and why any couldn't be.
    var transcribing: Set<UUID> = []
    var transcriptionErrors: [UUID: String] = [:]
    var isRecording = false
    var isImportingMailbox = false
    /// Where the last back or forward went, so it isn't remembered as a visit.
    @ObservationIgnored var isMovingThroughHistory = false
    var backStack: [UUID] = []
    var forwardStack: [UUID] = []
    /// Folders that changed again while being read.
    @ObservationIgnored var pendingRescans: Set<UUID> = []

    /// Set by `SHARE_EXTENSION` in Config/Stash.xcconfig.
    #if SHARE_EXTENSION
    static let sharingEnabled = true
    #else
    static let sharingEnabled = false
    #endif
    /// Where the share extension leaves things; nil when sharing is off.
    private let inbox: SharedInbox?

    /// The folder the main library's files are kept in.
    nonisolated static var mainSupportFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent(StashStore.isTestLibrary ? "StashTest" : "Stash", isDirectory: true)
    }

    init(context: ModelContext, support: URL = Library.mainSupportFolder, isMain: Bool = true) {
        self.context = context
        self.isMain = isMain
        supportFolder = support
        spotlight = SpotlightIndex(enabled: isMain)
        inbox = isMain && Library.sharingEnabled ? SharedInbox.forAppGroup() : nil
        widgetFolder = isMain && !StashStore.isTestLibrary ? WidgetSnapshot.folder() : nil
        finder = isMain && Library.sharingEnabled && !StashStore.isTestLibrary ? FinderShare.forAppGroup() : nil
        files = FileStore(root: support.appendingPathComponent("Files", isDirectory: true))
        index = SearchIndex(url: support.appendingPathComponent("SearchIndex.sqlite"))
        refreshAfterStoreChange()
        importSharedItems()
        startFinder()
        openIndexedFolders()
        startCheckingFeeds()
        startRunningRules()
        if Self.requestedTestItems > 0 { generateTestItems(Self.requestedTestItems) }

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

        guard SyncMonitor.isEnabled, isMain else { return }
        // Posted when changes arrive in the store from outside this
        // context -- in practice, from iCloud. The views update on their
        // own; the search index, merged tags and files need a hand.
        storeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    /// Stops what's running for this library, when another is opened in its place.
    func close() {
        feedTimer?.cancel()
        feedTimer = nil
        ruleTimer?.cancel()
        ruleTimer = nil
        folderWatchers = [:]
        for url in indexedFolderURLs.values { url.stopAccessingSecurityScopedResource() }
        indexedFolderURLs = [:]
        relockAll()
        for observer in [storeObserver, shareObserver, finderObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        save()
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

    /// `source`: the web address they came from, when known; otherwise each
    /// file's own "Where from", if it was downloaded.
    func importFiles(_ urls: [URL], source: URL? = nil) {
        var last: Item?
        for url in urls {
            let item = Item(kind: .document, title: url.deletingPathExtension().lastPathComponent)
            item.sourceAddress = source?.absoluteString ?? Self.whereFrom(url)
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
        if let last, arrivalTarget == nil { selection = last }
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
    func insert(_ item: Item, select: Bool = true) {
        context.insert(item)
        if let arrivalTarget {
            // Dropped on the Sorter: there, whatever the window's showing.
            if case .category(let category) = arrivalTarget { item.category = category }
            if item.category == nil { fileArrival(item) }
            save()
            reindex(item)
            return
        }
        switch sidebar {
        case .category(let category):
            item.category = category
        case .tag(let tag):
            item.tags = [tag]
        case .favorites:
            item.isFavorite = true
        case .templates where item.kind == .note:
            item.isTemplate = true
        case .list(let list):
            item.lists = [list]
            list.order = list.order + [item.uuid]
        case .readLater:
            item.readLaterAt = .now
        case .templates, .feed:
            sidebar = .all
        case .kind(let kind) where kind != item.kind:
            sidebar = .all
        case .smartFilter, .duplicates, .trash:
            sidebar = .all
        default:
            break
        }
        // Pages and files arriving with nowhere to go wait in the Inbox (or
        // the import destination); notes written here don't need filing.
        if item.category == nil, item.kind != .note || sidebar == .inbox {
            fileArrival(item)
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
        // A long editing session keeps a version every so often, not just at the end.
        if let baseline = editBaselines[item.uuid], Date.now.timeIntervalSince(baseline.since) > Self.versionInterval {
            keepVersion(of: item)
            beginEditing(item)
        }
    }

    // MARK: - Pictures in notes

    static let attachmentScheme = "attachment:"

    /// Stores a picture with a note and returns the Markdown that shows it.
    func addPicture(_ data: Data, fileExtension: String, to item: Item) -> String {
        let name = String(UUID().uuidString.prefix(8)).lowercased() + "." + (fileExtension.isEmpty ? "png" : fileExtension)
        let attachment = NoteAttachment(fileName: name, data: data)
        context.insert(attachment)
        attachment.item = item
        try? files.write(data, to: "\(item.uuid.uuidString)/Attachments/\(name)")
        save()
        // Words in the picture can be searched for.
        recognizeText(inPicture: name, of: item)
        return "![](\(Self.attachmentScheme)\(name))"
    }

    /// Where a picture in a note is: a stored attachment, written out if
    /// it's only just arrived from another device, or a web address.
    func pictureURL(_ source: String, in item: Item) -> URL? {
        guard source.hasPrefix(Self.attachmentScheme) else {
            return URL(string: source).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        }
        let name = String(source.dropFirst(Self.attachmentScheme.count))
        let path = "\(item.uuid.uuidString)/Attachments/\(name)"
        if item.isSealed {
            return unsealedCopy(of: path, synced: item.attachments?.first(where: { $0.fileName == name })?.data, for: item)
        }
        if !files.exists(path), let data = item.attachments?.first(where: { $0.fileName == name })?.data {
            try? files.write(data, to: path)
        }
        return files.exists(path) ? files.url(for: path) : nil
    }

    /// Pictures no longer in their note's text, a day after they were
    /// added (so one whose note hasn't synced yet isn't taken for unused).
    private func removeUnusedPictures() {
        let attachments = (try? context.fetch(FetchDescriptor<NoteAttachment>())) ?? []
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for attachment in attachments where attachment.createdAt < dayAgo {
            guard let item = attachment.item else {
                context.delete(attachment)
                continue
            }
            // A locked note's text is sealed, so it can't be read to see what it shows.
            if item.isSealed { continue }
            // A sketch's drawing stays while its picture does.
            var shown = attachment.fileName
            if shown.hasSuffix(".drawing") { shown = String(shown.dropLast(8)) + ".png" }
            if !item.body.contains(Self.attachmentScheme + shown) {
                try? FileManager.default.removeItem(at: files.url(for: "\(item.uuid.uuidString)/Attachments/\(attachment.fileName)"))
                context.delete(attachment)
            }
        }
    }

    // MARK: - Link graph

    var isShowingGraph = false
    var isAskingLibrary = false
    var isShowingStatistics = false
    var isShowingConcordance = false
    /// A PDF being split, and PDFs being imprinted (see PDFToolViews).
    var splittingPDF: Item?
    var imprintingItems: [Item]?
    /// Favourites at the top of the list, whatever it's sorted by.
    var favoritesFirst = Library.favoritesFirst {
        didSet { Library.favoritesFirst = favoritesFirst }
    }
    /// Quick Open, or Quick File for these items.
    var quickOpen: QuickOpenMode?
    var isImportingBookmarks = false
    /// Items waiting for a new list to be named, from a menu.
    var newListItems: [Item]?
    /// Items being renamed together.
    var renamingItems: [Item]?
    var isManagingLibraries = false
    /// Choosing a calendar event, and what for.
    var eventPicking: EventPicking?

    /// Items that link or are linked to, and the links between them (as
    /// pairs of indices): hand-made links and `[[links]]` in notes.
    func linkGraph() -> (items: [Item], links: [(Int, Int)]) {
        let all = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).filter { !$0.isTrashed && !$0.isTemplate }
        var byTitle: [String: Item] = [:]
        for item in all where !item.title.isEmpty {
            let key = WikiLinks.key(item.title)
            if byTitle[key] == nil { byTitle[key] = item }
        }
        var pairs: Set<[UUID]> = []
        for item in all {
            for target in item.linksTo ?? [] where target != item && !target.isTrashed {
                pairs.insert([item.uuid, target.uuid].sorted { $0.uuidString < $1.uuidString })
            }
            // A locked note's text isn't read.
            guard item.kind == .note, !item.isLocked else { continue }
            for title in WikiLinks.titles(in: item.body) {
                if let target = byTitle[WikiLinks.key(title)], target != item {
                    pairs.insert([item.uuid, target.uuid].sorted { $0.uuidString < $1.uuidString })
                }
            }
        }
        let linked = Set(pairs.flatMap { $0 })
        let items = all.filter { linked.contains($0.uuid) }
            .sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
        let index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.uuid, $0) })
        let links = pairs.compactMap { pair -> (Int, Int)? in
            guard let a = index[pair[0]], let b = index[pair[1]] else { return nil }
            return (a, b)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        return (items, links)
    }

    // MARK: - Markup

    /// Goes up each time a document's file changes in place, so views
    /// showing it load it again.
    private(set) var fileRevisions: [UUID: Int] = [:]
    /// Documents opened in another app to mark up (on a Mac, Preview), with
    /// their files' dates then: checked when Stash comes back to the front.
    @ObservationIgnored private var editingElsewhere: [UUID: Date] = [:]

    func fileRevision(of item: Item) -> Int { fileRevisions[item.uuid, default: 0] }

    /// Whether markup is offered: PDFs and pictures.
    static func canMarkUp(_ item: Item) -> Bool {
        // Files in an indexed folder are only read, never written.
        item.kind == .document && item.indexedFolder == nil && !item.isSealed
            && (item.isPDF || item.contentType?.conforms(to: .image) == true)
    }

    /// Keeps the file as first imported, the first time it's marked up.
    func keepOriginal(of item: Item) {
        guard let path = item.storedFilePath, files.exists(path) else { return }
        let original = files.originalPath(for: path)
        if !files.exists(original) { try? files.copy(path, to: original) }
    }

    func hasOriginal(_ item: Item) -> Bool {
        item.storedFilePath.map { files.exists(files.originalPath(for: $0)) } ?? false
    }

    /// Puts the file back as it was first imported, undoing all markup.
    func revertToOriginal(_ item: Item) {
        guard let path = item.storedFilePath else { return }
        let original = files.originalPath(for: path)
        guard files.exists(original), (try? files.copy(original, to: path)) != nil else { return }
        try? FileManager.default.removeItem(at: files.url(for: original))
        Task { await fileDidChange(item) }
    }

    /// After the file has been changed in place: what syncs, what's
    /// searched and the thumbnail follow it.
    func fileDidChange(_ item: Item) async {
        guard isAlive(item) else { return }
        item.fileData = syncableContents(of: item)
        item.contentHash = ""
        item.fileSize = 0
        item.thumbnailData = nil
        thumbnailsTried.remove(item.uuid)
        item.modifiedAt = .now
        fileRevisions[item.uuid, default: 0] += 1
        save()
        await fillContentHash(of: item)
        await fillThumbnail(of: item)
        await extractText(from: item)
    }

    #if os(macOS)
    /// Opens the document in Preview to mark it up; changes are picked up
    /// when Stash comes back to the front.
    func markUpInPreview(_ item: Item) {
        guard let url = localFile(for: item),
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        keepOriginal(of: item)
        editingElsewhere[item.uuid] = Self.modificationDate(of: url)
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif

    /// When Stash comes back to the front: has anything sent off to be
    /// marked up changed?
    func checkFilesEditedElsewhere() {
        guard !editingElsewhere.isEmpty else { return }
        for item in items(withIDs: Array(editingElsewhere.keys)) {
            guard let url = localFile(for: item) else { continue }
            let date = Self.modificationDate(of: url)
            if date != editingElsewhere[item.uuid] {
                editingElsewhere[item.uuid] = date
                Task { await fileDidChange(item) }
            }
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Merging and tidying

    /// Several notes made into one, each under its own heading, as
    /// DEVONthink's Merge does. The new note takes their tags, category
    /// and hand-made links; `[[links]]` to the old ones point at it; the
    /// old ones go to the Trash. Returns the new note.
    @discardableResult
    func mergeNotes(_ notes: [Item]) -> Item? {
        let ordered = notes.filter { $0.kind == .note && !$0.isTrashed && !$0.isLocked }
            .sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
        guard ordered.count > 1 else { return nil }
        let merged = Item(kind: .note, title: ordered[0].title.isEmpty ? "Merged Note" : ordered[0].title + " (merged)")
        merged.body = NoteMerge.merge(ordered.map { ($0.title, $0.body) })
        context.insert(merged)
        merged.category = ordered.first { $0.category != nil }?.category
        merged.isFavorite = ordered.contains(where: \.isFavorite)
        merged.rating = ordered.map(\.rating).max() ?? 0
        combine(ordered, into: merged)
        for note in ordered where !note.title.isEmpty {
            for linking in notesLinking(toTitle: note.title) where !ordered.contains(linking) {
                linking.body = WikiLinks.renaming(note.title, to: merged.title, in: linking.body)
                didEdit(linking)
            }
        }
        moveToTrash(ordered)
        save()
        reindex(merged)
        selection = merged
        return merged
    }

    /// Folds other copies of the same page or file into `keeper`: their
    /// tags, highlights, links, notes and stars join it, and they go to
    /// the Trash.
    func mergeDuplicates(into keeper: Item) {
        let copies = duplicates(of: keeper)
        guard !copies.isEmpty else { return }
        for copy in copies {
            let extra = copy.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty, !keeper.body.contains(extra) {
                keeper.body = keeper.body.isEmpty ? extra : keeper.body + "\n\n" + extra
            }
            keeper.isFavorite = keeper.isFavorite || copy.isFavorite
            keeper.rating = max(keeper.rating, copy.rating)
            if keeper.label == .none { keeper.label = copy.label }
            if keeper.category == nil { keeper.category = copy.category }
            if keeper.remindAt == nil { keeper.remindAt = copy.remindAt }
        }
        combine(copies, into: keeper)
        moveToTrash(copies)
        didEdit(keeper)
        save()
    }

    /// Tags, highlights and hand-made links from `items` onto `target`.
    private func combine(_ items: [Item], into target: Item) {
        var tags = target.tags ?? []
        var linksTo = target.linksTo ?? []
        for item in items {
            for tag in item.tags ?? [] where !tags.contains(tag) { tags.append(tag) }
            for other in item.linksTo ?? [] where other != target && !linksTo.contains(other) { linksTo.append(other) }
            for other in item.linkedFrom ?? [] where other != target && !(other.linksTo ?? []).contains(target) {
                other.linksTo = (other.linksTo ?? []) + [target]
            }
            for highlight in item.highlights ?? [] { highlight.item = target }
        }
        target.tags = tags
        target.linksTo = linksTo.filter { !items.contains($0) }
    }

    /// Notes that name the item without linking to it, for making links.
    func unlinkedMentions(of item: Item) -> [Item] {
        _ = revision
        let title = item.title.trimmingCharacters(in: .whitespaces)
        // A short title ("A", "To") is mentioned everywhere and means nothing.
        guard title.count >= 3 else { return [] }
        return notes(mentioning: title).filter { note in
            note != item && !note.isTrashed && !note.isLocked
                && !WikiLinks.unlinkedMentions(of: title, in: note.body).isEmpty
        }
    }

    /// Turns a note's mentions of the item into `[[links]]`.
    func linkMentions(in note: Item, to item: Item) {
        note.body = WikiLinks.linkingMentions(of: item.title, in: note.body)
        didEdit(note)
        save()
    }

    // MARK: - Locking

    /// Locked items unlocked since the app last went to the background.
    var unlocked: Set<UUID> = []
    var lockError: String?
    /// Asking for the locking password, and what to do with it.
    var passwordRequest: PasswordRequest?
    /// Vaults' keys, open until the app goes to the background.
    @ObservationIgnored var vaultKeys: [UUID: SymmetricKey] = [:]
    /// Unlocked sealed items' text, decrypted, in memory only.
    var openSeals: [UUID: SealedContents] = [:]

    /// Whether the item's contents are to be kept out of sight.
    func isHidden(_ item: Item) -> Bool {
        item.isLocked && !unlocked.contains(item.uuid)
    }

    /// Locking needs only a password now; kept for the menus that ask.
    static var canLock: Bool { true }

    private func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            if (error as? LAError)?.code == .passcodeNotSet {
                lockError = "Set a passcode on this device to use locked items."
            }
            return false
        }
    }

    /// Opens a locked item: with its key if it's to hand (from this session,
    /// or the Keychain behind Face ID or Touch ID), else by asking for the
    /// password.
    func unlock(_ item: Item) async {
        guard item.isLocked, !unlocked.contains(item.uuid) else { return }
        guard item.isSealed else {
            // Locked before encryption: unlocked as it always was, then sealed.
            if await authenticate("Unlock “\(item.displayTitle)”") {
                unlocked.insert(item.uuid)
                sealUnsealedLockedItems()
            }
            return
        }
        guard let key = await key(forVault: item.sealedVaultID, reason: "Unlock “\(item.displayTitle)”") else {
            passwordRequest = PasswordRequest(kind: .enter, then: .unlock(item.uuid))
            return
        }
        guard let contents = openSealedContents(of: item, key: key) else {
            lockError = "“\(item.displayTitle)” couldn’t be decrypted. It may have been locked with another password."
            return
        }
        openSeals[item.uuid] = contents
        unlocked.insert(item.uuid)
    }

    /// Encrypts items and locks them. The first time, a password is chosen.
    func lock(_ items: [Item]) {
        let candidates = items.filter { !$0.isLocked || !$0.isSealed }
        let lockable = candidates.filter { $0.indexedFolder == nil }
        if lockable.count < candidates.count {
            lockError = "Documents in an indexed folder can’t be locked: their files stay in the folder, where Stash can’t encrypt them."
        }
        guard !lockable.isEmpty else { return }
        guard let (vault, key) = currentKey() else {
            passwordRequest = PasswordRequest(kind: vaults().isEmpty ? .create : .enter, then: .lock(lockable.map(\.uuid)))
            return
        }
        for item in lockable {
            do {
                try seal(item, vault: vault, key: key)
            } catch {
                lockError = "“\(item.displayTitle)” couldn’t be encrypted: \(error.localizedDescription)"
                continue
            }
            item.isLocked = true
            unlocked.remove(item.uuid)
            openSeals[item.uuid] = nil
            reindex(item)
        }
        save()
        revision += 1
    }

    /// Items locked before locking encrypted: sealed once there's a key.
    func sealUnsealedLockedItems() {
        guard let (vault, key) = currentKey() else { return }
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.isLocked && $0.sealedData == nil })
        for item in (try? context.fetch(descriptor)) ?? [] where item.indexedFolder == nil {
            try? seal(item, vault: vault, key: key)
            if unlocked.contains(item.uuid) { openSeals[item.uuid] = openSealedContents(of: item, key: key) }
        }
        save()
    }

    /// Decrypts items and takes their locks off. Asks to unlock first:
    /// taking a lock off is as good as unlocking.
    func removeLock(from items: [Item]) async {
        let locked = items.filter(\.isLocked)
        guard !locked.isEmpty else { return }
        for item in locked {
            if item.isSealed {
                guard let key = await key(forVault: item.sealedVaultID, reason: "Remove the lock from “\(item.displayTitle)”") else {
                    passwordRequest = PasswordRequest(kind: .enter, then: .removeLock(locked.map(\.uuid)))
                    return
                }
                do {
                    try unseal(item, key: key)
                } catch {
                    lockError = "“\(item.displayTitle)” couldn’t be decrypted: \(error.localizedDescription)"
                    continue
                }
            } else if !unlocked.contains(item.uuid) {
                guard await authenticate("Remove the lock from “\(item.displayTitle)”") else { return }
            }
            item.isLocked = false
            unlocked.remove(item.uuid)
            openSeals[item.uuid] = nil
            reindex(item)
        }
        save()
        revision += 1
        Task { for item in locked where item.kind == .document { await fillThumbnail(of: item) } }
    }

    /// The password, given in answer to a request: chooses it or opens the
    /// key, then does what was waiting. False for a wrong password.
    func answer(_ request: PasswordRequest, password: String) async -> Bool {
        switch request.kind {
        case .create:
            do { try createVault(password: password) } catch {
                lockError = error.localizedDescription
                return false
            }
        case .enter:
            guard await openVaults(password: password) else { return false }
        }
        passwordRequest = nil
        sealUnsealedLockedItems()
        switch request.then {
        case .lock(let ids): lock(items(withIDs: ids))
        case .unlock(let id): if let item = items(withIDs: [id]).first { await unlock(item) }
        case .removeLock(let ids): await removeLock(from: items(withIDs: ids))
        }
        return true
    }

    /// Locks everything again, forgetting keys and decrypted copies: when
    /// the app goes to the background.
    func relockAll() {
        if !unlocked.isEmpty { unlocked = [] }
        if !openSeals.isEmpty { openSeals = [:] }
        vaultKeys = [:]
        removeUnsealedCopies()
    }

    // MARK: - Note history

    static let versionInterval: TimeInterval = 10 * 60
    static let versionsKept = 50

    /// How each note being edited read when editing began.
    @ObservationIgnored private var editBaselines: [UUID: (title: String, body: String, modifiedAt: Date, since: Date)] = [:]
    /// Which note's history is being looked at.
    var viewingHistoryOf: Item?

    func beginEditing(_ item: Item) {
        guard item.kind == .note else { return }
        editBaselines[item.uuid] = (item.title, item.body, item.modifiedAt, .now)
    }

    func endEditing(_ item: Item) {
        guard item.kind == .note, isAlive(item) else { return }
        keepVersion(of: item)
        editBaselines[item.uuid] = nil
    }

    /// Keeps the note as it read when editing began, if it's changed since.
    private func keepVersion(of item: Item) {
        guard !item.isSealed else { return }
        guard let baseline = editBaselines[item.uuid],
              baseline.body != item.body || baseline.title != item.title,
              // A note that was empty has nothing worth going back to.
              !baseline.body.isEmpty else { return }
        addVersion(to: item, title: baseline.title, body: baseline.body, savedAt: baseline.modifiedAt)
    }

    private func addVersion(to item: Item, title: String, body: String, savedAt: Date) {
        let version = NoteVersion(title: title, body: body, savedAt: savedAt)
        context.insert(version)
        version.item = item
        let versions = (item.versions ?? []).sorted { $0.savedAt > $1.savedAt }
        for old in versions.dropFirst(Self.versionsKept) { context.delete(old) }
        save()
    }

    /// Puts an earlier version's text back, keeping what's there now as a
    /// version of its own, so restoring can be undone the same way.
    func restore(_ version: NoteVersion) {
        guard let item = version.item else { return }
        addVersion(to: item, title: item.title, body: item.body, savedAt: item.modifiedAt)
        item.body = version.body
        didEdit(item)
        beginEditing(item)
        save()
    }

    func delete(_ version: NoteVersion) {
        context.delete(version)
        save()
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
        guard !item.isSealed else { return }
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
        guard !item.isSealed, let url = item.url, !copyingPages.contains(item.uuid) else { return }
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
        if item.isSealed { return unsealedCopy(of: path, synced: item.archiveData, for: item) }
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
        // An encrypted item's words stay sealed with it.
        guard !item.isSealed, let url = localFile(for: item) else { return }
        if item.contentType?.conforms(to: .emailMessage) == true {
            await readEmail(item, at: url)
            finishedReading(item)
            return
        }
        if item.contentType?.conforms(to: .audiovisualContent) == true {
            if await shouldTranscribe(item, at: url) { await transcribe(item) }
            finishedReading(item)
            return
        }
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
        if item.indexedFolder != nil { return indexedFile(for: item) }
        guard let path = item.storedFilePath else { return nil }
        // Encrypted: a decrypted copy while it's unlocked, nothing otherwise.
        if item.isSealed { return unsealedCopy(of: path, synced: item.fileData, for: item) }
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
            reminders?.schedule(item)
        }
        save()
        runSearch()
        if date != nil, let reminders { Task { await reminders.requestPermission() } }
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
        if item.category == nil { fileArrival(item) }
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
    func arrived(_ item: Item) {
        awaitingRules.insert(item.uuid)
        applyRules(to: item)
    }

    /// Runs the rules again on an item that arrived this session, now its
    /// page or document has been read.
    func finishedReading(_ item: Item) {
        guard awaitingRules.remove(item.uuid) != nil, isAlive(item) else { return }
        applyRules(to: item)
    }

    private func enabledRules() -> [SmartRule] {
        let rules = (try? context.fetch(FetchDescriptor<SmartRule>(predicate: #Predicate { $0.isEnabled }))) ?? []
        return rules.sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
    }

    private func applyRules(to item: Item) {
        guard !item.isTrashed else { return }
        for rule in enabledRules() where compile(rule.query).matches(item) {
            apply(rule, to: item)
        }
    }

    /// Runs one rule over everything already in the library that matches
    /// it, and says how many that was.
    @discardableResult
    func apply(_ rule: SmartRule, toExisting: Bool) -> Int {
        let search = compile(rule.query)
        let items = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).filter { !$0.isTrashed && search.matches($0) }
        for item in items { apply(rule, to: item) }
        rule.lastRunAt = .now
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
        reminders?.cancel(items)
        save()
        revision += 1
        runSearch()
    }

    func restore(_ items: [Item]) {
        deselect(items)
        for item in items {
            item.trashedAt = nil
            spotlight.update(item)
            reminders?.schedule(item)
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
            // The file stays in its folder, and mustn't come straight back.
            if let folder = item.indexedFolder, let path = item.indexedPath { folder.ignore(path) }
            index?.remove(item.uuid)
            context.delete(item)
        }
        spotlight.remove(items.map(\.uuid))
        reminders?.cancel(items)
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
            // A category made in the share sheet: "Work › Clients" or "Work/Clients".
            if item.category == nil, let path = entry.newCategory, !path.isEmpty {
                let names = path.components(separatedBy: CharacterSet(charactersIn: "›/"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                item.category = names.reduce(nil as ItemCategory?) { parent, name in importCategory(named: name, in: parent) ?? parent }
            }
            if item.category == nil { fileArrival(item) }
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
        let named = ((try? context.fetch(descriptor)) ?? []).filter { WikiLinks.key($0.title) == key && !$0.isTemplate }
        // One in the Trash is only the answer when there's nothing else.
        if let found = named.first(where: { !$0.isTrashed }) { return found }
        // Then one known by that name as an alias.
        let aliasDescriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.aliases.localizedStandardContains(trimmed) })
        let aliased = ((try? context.fetch(aliasDescriptor)) ?? []).filter { item in
            !item.isTemplate && !item.isTrashed && Aliases.split(item.aliases).contains { WikiLinks.key($0) == key }
        }
        return aliased.min { $0.uuid.uuidString < $1.uuid.uuidString } ?? named.first
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
        let names = [item.title] + Aliases.split(item.aliases)
        var seen: Set<Item> = []
        return names.flatMap(notesLinking(toTitle:)).filter { $0 != item && !$0.isTrashed && seen.insert($0).inserted }
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
        case .recents: "Recents"
        case .unfiled: "Unfiled"
        case .reminders: "Reminders"
        case .kind(let kind): kind.pluralName
        case .category(let category): category.name
        case .tag(let tag): "#" + tag.name
        case .smartFilter(let filter): filter.name
        case .duplicates: "Duplicates"
        case .trash: "Trash"
        case .templates: "Templates"
        case .feed(let feed): feed.title
        case .list(let list): list.name
        case .readLater: "Read Later"
        case .timeline: "Timeline"
        }
    }

    /// `items` narrowed to the sidebar selection and the search: best match
    /// first while searching by word, otherwise in the chosen order.
    func visibleItems(from items: [Item]) -> [Item] {
        if sidebar == .duplicates { return duplicates(among: items).flatMap { $0 } }
        var result = items.filter(isInSidebar)
        if !search.isEmpty { result = result.filter(search.matches) }
        if !tagFilter.isEmpty { result = result.filter { TagFilter.matches(($0.tags ?? []).map(\.name), chosen: tagFilter) } }
        if search.isRanked { return search.rank(result) }
        if sidebar == .recents {
            let kind = recentsKind
            let date = { (item: Item) in Recents.date(kind, created: item.createdAt, modified: item.modifiedAt, viewed: item.lastViewedAt) ?? .distantPast }
            return result.sorted { date($0) > date($1) }
        }
        if sidebar == .reminders {
            return result.sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
        }
        // A list in its own order; the reading queue oldest first.
        if case .list(let list) = sidebar {
            let order = list.orderedItems.map(\.uuid)
            let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return result.sorted { position[$0.uuid, default: .max] < position[$1.uuid, default: .max] }
        }
        if sidebar == .readLater {
            return result.sorted { ($0.readLaterAt ?? .distantPast) < ($1.readLaterAt ?? .distantPast) }
        }
        let sorted = sort.sorted(result, ascending: sortAscending)
        return favoritesFirst ? favoritesToTop(sorted) : sorted
    }

    private func isInSidebar(_ item: Item) -> Bool {
        let selection = sidebar ?? .all
        if selection == .trash { return item.isTrashed }
        guard !item.isTrashed else { return false }
        // Templates keep to themselves.
        if item.isTemplate || selection == .templates { return item.isTemplate && selection == .templates }
        switch selection {
        case .all, .trash, .duplicates, .templates, .timeline: return true
        case .recents:
            let date = Recents.date(recentsKind, created: item.createdAt, modified: item.modifiedAt, viewed: item.lastViewedAt)
            return Recents.isRecent(date, days: recentsDays)
        case .unfiled: return item.category == nil
        case .feed(let feed): return item.feed == feed
        case .list(let list): return (item.lists ?? []).contains(list)
        case .readLater: return item.readLaterAt != nil
        case .inbox: return item.inInbox
        case .favorites: return item.isFavorite
        case .reminders: return item.remindAt != nil
        case .kind(let kind): return item.kind == kind
        case .category(let category): return category.contains(item.category)
        case .tag(let tag): return (item.tags ?? []).contains(tag)
        case .smartFilter(let filter):
            if let scope = filter.category, !scope.contains(item.category) { return false }
            if let list = filter.list, !(item.lists ?? []).contains(list) { return false }
            return smartFilterSearch?.matches(item) ?? true
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

    func runSearch() {
        search = compile(query)
        compileSmartFilter()
    }

    private func compileSmartFilter() {
        if case .smartFilter(let filter) = sidebar {
            smartFilterSearch = compile(filter.query)
        } else {
            smartFilterSearch = nil
        }
    }

    // MARK: - Smart filters

    @discardableResult
    func newSmartFilter(named name: String, query: String, in scope: SmartFilterScope = .library) -> SmartFilter? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let filter = SmartFilter(name: trimmed, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(filter)
        filter.scope = scope
        save()
        return filter
    }

    func update(_ filter: SmartFilter, name: String, query: String, scope: SmartFilterScope? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { filter.name = trimmed }
        filter.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scope { filter.scope = scope }
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
        return ids.compactMap { byID[$0] }.filter { !$0.isTrashed && !$0.isLocked && !$0.isTemplate }.prefix(limit).map { $0 }
    }

    // MARK: - Shortcuts and Spotlight

    func items(withIDs ids: [UUID]) -> [Item] {
        let found = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.uuid) }))) ?? []
        let byID = Dictionary(found.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Items matching search text, as typed in the search field, best first.
    func find(_ text: String, limit: Int = 50) -> [Item] {
        let compiled = compile(text)
        let all = (try? context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        return Array(compiled.rank(all.filter { !$0.isTrashed && compiled.matches($0) }).prefix(limit))
    }

    /// Shows an item opened from Spotlight or Shortcuts.
    func show(_ item: Item) {
        if item.isTrashed {
            sidebar = .trash
        } else if item.isTemplate {
            sidebar = .templates
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
        let started = ContinuousClock.now
        defer { Self.performanceLog.info("Refreshed after a store change in \(ContinuousClock.now - started)") }
        if let selection, !isAlive(selection) { self.selection = nil }
        mergeDuplicates()
        deleteOldTrash()
        removeUnusedPictures()
        // Only tidy files away when the library definitely loaded: an empty
        // list from a failed fetch would otherwise delete every document.
        guard let items = try? context.fetch(FetchDescriptor<Item>()) else { return }
        // Only what's changed since the index last saw it is indexed again.
        let byID = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = index?.sync(byID.mapValues(Self.indexSignature)) { id in byID[id].map(entry(for:)) }
        if spotlight.needsRebuild || changes == nil {
            spotlight.replaceAll(with: items)
        } else if let changes {
            for id in changes.changed { if let item = byID[id] { spotlight.update(item) } }
            spotlight.remove(changes.removed)
        }
        reminders?.replaceAll(with: items)
        fillFileSizes(items)
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
        mergeDuplicateLists()
        mergeDuplicateFields()
        mergeDuplicateFeeds()
        save()
    }

    /// Lists of the same name, made on two devices: one, with both's items,
    /// the survivor's order first.
    private func mergeDuplicateLists() {
        let lists = (try? context.fetch(FetchDescriptor<ItemList>())) ?? []
        for group in Dictionary(grouping: lists, by: { $0.name.lowercased() }).values where group.count > 1 {
            let ordered = group.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            let keeper = ordered[0]
            var order = keeper.orderedItems.map(\.uuid)
            for duplicate in ordered.dropFirst() {
                for item in duplicate.orderedItems where !(item.lists ?? []).contains(keeper) {
                    item.lists = (item.lists ?? []) + [keeper]
                    order.append(item.uuid)
                }
                if sidebar == .list(duplicate) { sidebar = .list(keeper) }
                context.delete(duplicate)
            }
            keeper.order = order
        }
    }

    /// Fields of the same name and kind: one, with the values moved over
    /// (an item with both keeps the survivor's).
    private func mergeDuplicateFields() {
        let fields = (try? context.fetch(FetchDescriptor<FieldDefinition>())) ?? []
        for group in Dictionary(grouping: fields, by: { $0.name.lowercased() + "|" + $0.kindRaw }).values where group.count > 1 {
            let ordered = group.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            let keeper = ordered[0]
            let gone = Set(ordered.dropFirst().map(\.uuid))
            let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { !$0.customFields.isEmpty }))) ?? []
            for item in items {
                var values = CustomField.decode(item.customFields)
                var changed = false
                for id in gone {
                    guard let value = values.removeValue(forKey: id) else { continue }
                    if values[keeper.uuid, default: ""].isEmpty { values[keeper.uuid] = value }
                    changed = true
                }
                if changed { item.customFields = CustomField.encode(values) }
            }
            keeper.choiceList = Array(NSOrderedSet(array: ordered.flatMap(\.choiceList))) as? [String] ?? keeper.choiceList
            for duplicate in ordered.dropFirst() { context.delete(duplicate) }
        }
    }

    /// The same feed subscribed to on two devices: one, with both's posts,
    /// and what either has seen.
    private func mergeDuplicateFeeds() {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        for group in Dictionary(grouping: feeds, by: \.urlString).values where group.count > 1 {
            let ordered = group.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                for item in duplicate.items ?? [] { item.feed = keeper }
                keeper.markSeen(duplicate.seenIDs.split(separator: "\n").map(String.init).reversed())
                if sidebar == .feed(duplicate) { sidebar = .feed(keeper) }
                context.delete(duplicate)
            }
        }
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
        index?.update(entry(for: item), signature: Self.indexSignature(item))
        spotlight.update(item)
        revision += 1
        if !query.isEmpty { runSearch() }
    }

    /// A search as typed, knowing the custom fields there are.
    func compile(_ text: String) -> CompiledSearch {
        let fields = fieldDefinitions()
        return CompiledSearch(SearchQuery(text, fields: fields.map(\.name)), index: index, fields: fields)
    }

    private func entry(for item: Item) -> SearchIndex.Entry {
        // A locked item is found by its title and tags only.
        if item.isLocked {
            return SearchIndex.Entry(id: item.uuid, title: Self.indexedTitle(item), body: "",
                                     tags: item.sortedTags.map(\.name).joined(separator: " "), extra: "")
        }
        let fileName = item.storedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let highlights = item.sortedHighlights
        // Highlights and their notes are your own words about it, so they
        // count with the body; the rest of the document's text counts least.
        let body = ([item.body, item.summary] + highlights.flatMap { [$0.text, $0.note] })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return SearchIndex.Entry(
            id: item.uuid,
            title: Self.indexedTitle(item),
            body: body,
            tags: item.sortedTags.map(\.name).joined(separator: " "),
            extra: ([item.urlString ?? "", fileName, item.extractedText]
                    // Your own fields' values, and the words in sketches and pictures.
                    + CustomField.decode(item.customFields).values
                    + (item.attachments ?? []).map(\.recognizedText)).joined(separator: "\n"))
    }

    /// Makes a document's thumbnail, if it hasn't one yet.
    func fillThumbnail(of item: Item) async {
        guard item.kind == .document, !item.isSealed, item.thumbnailData == nil, thumbnailsTried.insert(item.uuid).inserted,
              let url = localFile(for: item) else { return }
        guard let data = await Thumbnails.make(forFileAt: url), isAlive(item) else { return }
        item.thumbnailData = data
        save()
    }

    /// Works out a document's hash, for finding duplicates, if it hasn't been yet.
    func fillContentHash(of item: Item) async {
        guard item.kind == .document, !item.isSealed, item.contentHash.isEmpty, let url = localFile(for: item) else { return }
        let hash = await Task.detached(priority: .utility) { FileStore.sha256(of: url) }.value
        guard let hash, isAlive(item) else { return }
        item.contentHash = hash
        if item.fileSize == 0 { item.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        save()
        revision += 1
    }

    // MARK: - Saving

    func save() {
        try? context.save()
        storeVersion += 1
        scheduleWidgetUpdate()
        scheduleFinderUpdate()
    }

    /// Goes up with every save, so counts worked out from the store (the
    /// sidebar's badges) know when to work themselves out again.
    var storeVersion = 0
    @ObservationIgnored private var cachedCounts: (version: Int, counts: SidebarCounts)?

    /// The sidebar's badges: counted by the store, not by loading every item,
    /// and only again after something's been saved.
    func sidebarCounts() -> SidebarCounts {
        if let cachedCounts, cachedCounts.version == storeVersion { return cachedCounts.counts }
        let now = Date.now
        func count(_ predicate: Predicate<Item>) -> Int {
            (try? context.fetchCount(FetchDescriptor<Item>(predicate: predicate))) ?? 0
        }
        let note = ItemKind.note.rawValue
        let candidates = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate {
            $0.kindRaw != note && $0.trashedAt == nil
        }))) ?? []
        let counts = SidebarCounts(
            inbox: count(#Predicate { $0.inInbox && $0.trashedAt == nil }),
            // Few items have reminders: those are checked one by one.
            due: ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt == nil && $0.remindAt != nil }))) ?? [])
                .filter { ($0.remindAt ?? .distantFuture) <= now }.count,
            readLater: count(#Predicate { $0.trashedAt == nil && $0.readLaterAt != nil && $0.readingProgress < 0.98 }),
            duplicates: duplicates(among: candidates).count)
        cachedCounts = (storeVersion, counts)
        return counts
    }

    /// What the index's entry for an item is made from, cheaply: when it
    /// changes, the entry is made again. Lengths stand in for long text.
    /// Its title and aliases: found by either, as a title match.
    static func indexedTitle(_ item: Item) -> String {
        item.aliases.isEmpty ? item.title : item.title + "\n" + Aliases.split(item.aliases).joined(separator: "\n")
    }

    static func indexSignature(_ item: Item) -> String {
        [String(item.modifiedAt.timeIntervalSince1970), item.isLocked ? "locked" : "", item.title, item.aliases,
         String(item.body.utf16.count), String(item.summary.utf16.count), String(item.extractedText.utf16.count),
         item.urlString ?? "", item.sortedTags.map(\.name).joined(separator: ","),
         String((item.highlights ?? []).reduce(0) { $0 + $1.text.utf16.count + $1.note.utf16.count }),
         String(item.customFields.utf16.count),
         String((item.attachments ?? []).reduce(0) { $0 + $1.recognizedText.utf16.count })]
            .joined(separator: "|")
    }

    // MARK: - Widgets

    @ObservationIgnored private var pendingWidgetUpdate: Task<Void, Never>?
    /// Where the widgets read from; nil without an App Group.
    @ObservationIgnored private let widgetFolder: URL?
    /// What the Finder shows (see FinderPublishing); nil when sharing is off.
    @ObservationIgnored let finder: FinderShare?
    @ObservationIgnored var pendingFinderUpdate: Task<Void, Never>?

    /// Saves come in bursts while typing; the widgets are told once it settles.
    private func scheduleWidgetUpdate() {
        guard widgetFolder != nil else { return }
        pendingWidgetUpdate?.cancel()
        pendingWidgetUpdate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.publishWidgets()
        }
    }

    /// Writes what the widgets show, and asks them to look again.
    func publishWidgets() {
        guard let widgetFolder,
              let items = try? context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])) else { return }
        let live = items.filter { !$0.isTrashed && !$0.isTemplate }
        func entry(_ item: Item) -> WidgetSnapshot.Entry {
            WidgetSnapshot.Entry(id: item.uuid, title: item.displayTitle, kind: item.kindRaw,
                                 subtitle: item.isLocked ? "Locked" : item.listSubtitle, date: item.remindAt)
        }
        let snapshot = WidgetSnapshot(
            updatedAt: .now,
            recent: live.prefix(8).map(entry),
            favorites: live.filter(\.isFavorite).prefix(8).map(entry),
            reminders: live.filter { $0.remindAt != nil }
                .sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
                .prefix(8).map(entry),
            inboxCount: live.filter(\.inInbox).count)
        try? snapshot.write(to: widgetFolder)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// `stash://` links from the widgets: an item, or a new note.
    func open(stashURL url: URL) {
        // `stash://new-note` with nothing in it, from the widgets: a blank note to write.
        if url.host == "new-note", URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty ?? true {
            sidebar = .all
            newNote()
        } else if let request = StashURL.parse(url) {
            perform(request)
        } else {
            open(wikiURL: url)
        }
    }

    /// False once an item has been deleted -- checked after anything slow,
    /// like a download, before writing to it.
    func isAlive(_ item: Item) -> Bool {
        item.modelContext != nil && !item.isDeleted
    }
}
