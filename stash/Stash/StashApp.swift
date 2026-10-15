import SwiftUI
import SwiftData

/// One of the libraries: the main one (synced, if sync is on) or another
/// kept on this device, as DEVONthink keeps several databases.
struct LibraryInfo: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date

    /// The main library's id: it was the only one before there were others.
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Where categories other people share with you are kept (see Sharing).
    static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    var isMain: Bool { id == Self.mainID }
    var isShared: Bool { id == Self.sharedID }
}

/// The open library, made at launch and whenever another is chosen.
/// Shortcuts can start the app without showing it, so it can't wait for
/// the window to be made.
@MainActor
@Observable
final class StashStore {
    static let shared = StashStore()

    private(set) var container: ModelContainer
    private(set) var library: Library
    /// Every library, the main one first.
    private(set) var libraries: [LibraryInfo]
    private(set) var current: LibraryInfo

    /// Launched with `-StashTestLibrary YES` (or `STASH_TEST_LIBRARY` set):
    /// a separate library to try things in, never synced, kept out of
    /// Spotlight, notifications and widgets, leaving the real one alone.
    nonisolated static let isTestLibrary = UserDefaults.standard.bool(forKey: "StashTestLibrary")
        || ProcessInfo.processInfo.environment["STASH_TEST_LIBRARY"] != nil

    static let schema = Schema([Item.self, Tag.self, ItemCategory.self, SmartFilter.self, Highlight.self, SmartRule.self,
                                NoteVersion.self, NoteAttachment.self, Feed.self, IndexedFolder.self, Vault.self,
                                ItemList.self, FieldDefinition.self, Notebook.self, StudyCard.self])

    private static var librariesKey: String { isTestLibrary ? "testLibraries" : "libraries" }
    private static var currentKey: String { isTestLibrary ? "testCurrentLibrary" : "currentLibrary" }

    /// Where libraries other than the main one are kept, a folder each.
    static var otherLibrariesFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent(isTestLibrary ? "StashTest Libraries" : "Stash Libraries",
                                                                 isDirectory: true)
    }

    private init() {
        if Self.isTestLibrary, UserDefaults.standard.bool(forKey: "StashResetTestLibrary") {
            // UI tests start each run from nothing.
            try? FileManager.default.removeItem(at: Library.mainSupportFolder)
            try? FileManager.default.removeItem(at: Self.otherLibrariesFolder)
            UserDefaults.standard.removeObject(forKey: Self.librariesKey)
            UserDefaults.standard.removeObject(forKey: Self.currentKey)
        }
        let saved = UserDefaults.standard.data(forKey: Self.librariesKey)
            .flatMap { try? JSONDecoder().decode([LibraryInfo].self, from: $0) } ?? []
        var libraries = saved.filter { !$0.isMain }
        let main = saved.first(where: \.isMain) ?? LibraryInfo(id: LibraryInfo.mainID, name: "Stash", createdAt: .distantPast)
        libraries.insert(main, at: 0)
        let chosen = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        let current = libraries.first { $0.id == chosen } ?? main
        let opened = Self.open(current)
        self.libraries = libraries
        self.current = current
        container = opened.container
        library = opened.library
        // Choosing a reminder's notification opens its item (reminders are the main library's).
        Reminders.shared.onOpen = { id in
            let library = StashStore.shared.library
            if let item = library.items(withIDs: [id]).first { library.show(item) }
        }
        Reminders.shared.start()
    }

    private static func open(_ info: LibraryInfo) -> (container: ModelContainer, library: Library) {
        let configuration: ModelConfiguration
        let support: URL
        if info.isMain {
            support = Library.mainSupportFolder
            if isTestLibrary {
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                configuration = ModelConfiguration(schema: schema, url: support.appendingPathComponent("Library.store"),
                                                   cloudKitDatabase: .none)
            } else {
                // Syncs through the iCloud container named in the entitlements,
                // which only exist when ICLOUD_SYNC is on (Config/Stash.xcconfig).
                // Said explicitly either way: left to itself SwiftData syncs
                // whenever it finds an iCloud entitlement.
                #if ICLOUD_SYNC
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
                #else
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                #endif
            }
        } else {
            // Other libraries stay on this device.
            support = supportFolder(for: info)
            configuration = localConfiguration(for: info)
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the library “\(info.name)”: \(error)")
        }
        return (container, Library(context: container.mainContext, support: support, isMain: info.isMain))
    }

    /// A library other than the main one: its folder, and its store, on this device only.
    static func supportFolder(for info: LibraryInfo) -> URL {
        let folder = otherLibrariesFolder.appendingPathComponent(info.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func localConfiguration(for info: LibraryInfo) -> ModelConfiguration {
        ModelConfiguration(info.id.uuidString, schema: schema, url: supportFolder(for: info).appendingPathComponent("Library.store"),
                           cloudKitDatabase: .none)
    }

    /// The library shared categories arrive in, made the first time one does.
    @discardableResult
    func ensureSharedLibrary() -> LibraryInfo {
        if let existing = libraries.first(where: \.isShared) { return existing }
        let info = LibraryInfo(id: LibraryInfo.sharedID, name: "Shared with Me", createdAt: .now)
        libraries.append(info)
        saveList()
        return info
    }

    // MARK: - Managing

    func switchTo(_ info: LibraryInfo) {
        guard info != current, libraries.contains(info) else { return }
        library.close()
        let opened = Self.open(info)
        container = opened.container
        library = opened.library
        current = info
        UserDefaults.standard.set(info.id.uuidString, forKey: Self.currentKey)
        // Changes to shared categories that waited for this library.
        Sharing.shared?.schedulePublish()
    }

    @discardableResult
    func createLibrary(named name: String) -> LibraryInfo? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let info = LibraryInfo(id: UUID(), name: trimmed, createdAt: .now)
        libraries.append(info)
        saveList()
        return info
    }

    func rename(_ info: LibraryInfo, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = libraries.firstIndex(of: info) else { return }
        libraries[index].name = trimmed
        if current.id == info.id { current = libraries[index] }
        saveList()
    }

    /// Deletes a library other than the main one, and everything in it.
    func delete(_ info: LibraryInfo) {
        guard !info.isMain, libraries.contains(info) else { return }
        if current.id == info.id, let main = libraries.first { switchTo(main) }
        libraries.removeAll { $0.id == info.id }
        saveList()
        try? FileManager.default.removeItem(at: Self.otherLibrariesFolder.appendingPathComponent(info.id.uuidString))
    }

    private func saveList() {
        UserDefaults.standard.set(try? JSONEncoder().encode(libraries), forKey: Self.librariesKey)
    }
}

@main
struct StashApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(StashAppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(StashMacAppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    #endif
    @State private var store = StashStore.shared
    @State private var sync = SyncMonitor()

    private var container: ModelContainer { store.container }
    private var library: Library { store.library }

    init() {
        // Sharing through iCloud, once the store's open (only with sync on).
        Task { @MainActor in Sharing.shared?.start() }
    }

    var body: some Scene {
        #if os(macOS)
        // One window: the library is one place, and a second window onto it
        // would only have to be kept in step with the first.
        Window("Stash", id: "main") {
            ContentView()
                .environment(library)
                .environment(sync)
                // Another library: everything showing starts again.
                .id(store.current.id)
        }
        .modelContainer(container)
        .commands {
            StashCommands(library: library)
            // Import from iPhone or iPad: take a photo or scan a document
            // with the phone, straight into Stash.
            ImportFromDevicesCommands()
        }

        MenuBarExtra("Stash", systemImage: "tray.and.arrow.down", isInserted: $showMenuBarExtra) {
            QuickCaptureView()
                .environment(library)
                .id(store.current.id)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        // An item in a window (or tab) of its own: double-click it, or
        // Open in New Window.
        WindowGroup("Item", id: "item", for: UUID.self) { $id in
            ItemWindow(id: id)
                .environment(library)
                .id(store.current.id)
                .environment(sync)
        }
        .modelContainer(container)
        .defaultSize(width: 860, height: 680)

        Window("Statistics", id: "stats") {
            StatisticsView(showsDone: false)
                .environment(library)
                .modelContainer(container)
                .id(store.current.id)
        }
        .defaultSize(width: 640, height: 720)

        Window("Ask Your Library", id: "ask") {
            AskLibraryView(showsDone: false)
                .environment(library)
                .id(store.current.id)
                .modelContainer(container)
        }
        .defaultSize(width: 560, height: 640)

        Window("Concordance", id: "concordance") {
            ConcordanceView(showsDone: false)
                .environment(library)
                .id(store.current.id)
                .modelContainer(container)
        }
        .defaultSize(width: 520, height: 600)

        // Floats above other apps, to drop things onto.
        Window("Sorter", id: "sorter") {
            SorterView()
                .environment(library)
                .id(store.current.id)
                .modelContainer(container)
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .keyboardShortcut("s", modifiers: [.command, .option])

        Window("Link Graph", id: "graph") {
            LinkGraphView()
                .environment(library)
                .id(store.current.id)
                .modelContainer(container)
        }
        .defaultSize(width: 800, height: 600)
        #else
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(sync)
                // Another library: everything showing starts again.
                .id(store.current.id)
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(FeedRefresh.identifier)) {
            await FeedRefresh.run()
        }
        .commands { PadCommands(library: library) }

        // An item in a window of its own, beside another on an iPad.
        WindowGroup("Item", id: "item", for: UUID.self) { $id in
            ItemWindow(id: id)
                .environment(library)
                .environment(sync)
                .id(store.current.id)
        }
        .modelContainer(container)
        #endif
    }
}

#if os(macOS)
struct StashCommands: Commands {
    let library: Library
    @FocusedValue(\.windowItem) private var windowItem
    @Environment(\.openWindow) private var openWindow

    /// What the menus act on: an item window's item, or the main window's selection.
    private var chosenItems: [Item] { windowItem.map { [$0] } ?? library.selectedItems }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { library.newNote() }
                .keyboardShortcut("n")
            Button("New Voice Note") { library.isRecording = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Today’s Note") { library.openToday() }
                .keyboardShortcut("0")
            Button("Quick Open…") { library.quickOpen = .open }
                .keyboardShortcut("o")
            Button("Command Palette…") { library.isShowingPalette = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("New Mind Map") { library.newMindMap() }
            Button("New Sheet") { library.newSheet() }
            Button("New Note for Event…") { library.eventPicking = .newNote }
            Menu("New from Template") {
                // Read on every change of selection, which making a template is.
                let _ = library.selection
                TemplateMenuItems(library: library, templates: library.templates())
            }
            Divider()
            Button("Add Link…") { library.isAddingLink = true }
                .keyboardShortcut("l")
            Button("Subscribe to Feed…") { library.isAddingFeed = true }
                .keyboardShortcut("u", modifiers: [.command, .option])
            // Cmd-I is italic in a note, so importing has only the Option form.
            Button("Import Documents…") { library.isImporting = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Index Folder…") { library.isChoosingFolderToIndex = true }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { library.printRequest = windowItem ?? library.selection }
                .keyboardShortcut("p")
                .disabled(windowItem == nil && library.selection == nil)
            Button("Save as PDF…") { library.pdfRequest = windowItem ?? library.selection }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(windowItem == nil && library.selection == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import from Evernote…") { library.isImportingEvernote = true }
            Button("Import Notes Folder…") { library.isImportingNotesFolder = true }
            Button("Import Mailbox…") { library.isImportingMailbox = true }
            Button("Import Bookmarks or Links…") { library.isImportingBookmarks = true }
            Button("Import Feeds (OPML)…") { library.isImportingFeeds = true }
            Divider()
            Button(chosenItems.count > 1 ? "Export Items…" : "Export Item…") {
                let chosen = chosenItems
                let name = chosen.count == 1 ? chosen[0].displayTitle : "\(chosen.count) Items"
                library.exportRequest = .items(chosen, name: name)
            }
            .keyboardShortcut("e")
            .disabled(chosenItems.isEmpty)
            Button("Export Everything…") { library.exportRequest = .everything }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Export All Highlights…") { library.exportRequest = .highlights }
            Divider()
            Button("Restore from Backup…") { library.isRestoring = true }
        }
        CommandMenu("Item") {
            let chosen = chosenItems
            Button("Open in New Window") { for item in chosen { openWindow.item(item, asTab: false) } }
                .disabled(chosen.isEmpty || windowItem != nil)
            Button("Open in New Tab") { for item in chosen { openWindow.item(item, asTab: true) } }
                .disabled(chosen.isEmpty || windowItem != nil)
            Divider()
            let live = chosen.filter { !$0.isTrashed }
            if live.count == 1 {
                Button("Copy Item Link") { library.copyItemLink(live[0]) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Copy Markdown Link") { library.copyMarkdownLink(live[0]) }
                ImageSearchMenu(item: live[0])
                    .environment(library)
            }
            let allFavorite = !live.isEmpty && live.allSatisfy(\.isFavorite)
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") {
                library.setFavorite(live, !allFavorite)
            }
            .keyboardShortcut("d")
            .disabled(live.isEmpty)
            let anyUnread = chosen.contains(where: \.isUnread)
            Button(anyUnread ? "Mark as Read" : "Mark as Unread") {
                library.setUnread(chosen, !anyUnread)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(chosen.isEmpty)
            Button("Done (Take Out of Inbox)") { library.markFiled(chosen) }
                .disabled(!chosen.contains(where: \.inInbox))
            Button("Add Tags…") { library.taggingItems = live }
                .keyboardShortcut("t")
                .disabled(live.isEmpty)
            Button("Remind Me…") { library.remindingItems = live }
                .disabled(live.isEmpty)
            let allQueued = !live.isEmpty && live.allSatisfy { $0.readLaterAt != nil }
            Button(allQueued ? "Remove from Read Later" : "Read Later") { library.setReadLater(live, !allQueued) }
                .keyboardShortcut("r")
                .disabled(live.isEmpty)
            let allLocked = !live.isEmpty && live.allSatisfy(\.isLocked)
            Button(allLocked ? "Remove Lock…" : "Lock") {
                if allLocked { Task { await library.removeLock(from: live) } } else { library.lock(live) }
            }
            .keyboardShortcut("j")
            .disabled(live.isEmpty)
            Button("Lock All Again") { library.relockAll() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Move to Trash") { library.moveToTrash(live) }
                .keyboardShortcut(.delete)
                .disabled(live.isEmpty)
            Button("Put Back") { library.restore(chosen.filter(\.isTrashed)) }
                .disabled(!chosen.contains(where: \.isTrashed))
            Divider()
            let notes = live.filter { $0.kind == .note }
            if notes.count == 1, notes[0].isTemplate {
                Button("New Note from Template") { library.newNote(from: notes[0]) }
            } else {
                Button("Save as Template") { library.saveAsTemplate(notes[0]) }
                    .disabled(notes.count != 1)
            }
            Button(chosen.count > 1 ? "Rename Items…" : "Rename…") { library.renamingItems = live }
                .disabled(live.isEmpty)
            Button("Move to Category…") { library.quickOpen = .file(live) }
                .keyboardShortcut("g")
                .disabled(live.isEmpty)
            Button("Show in Category") { if let item = live.first { library.showInCategory(item) } }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(live.first?.category == nil)
            Button("Duplicate") { library.duplicate(live) }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!live.contains { !$0.isLocked })
            Menu("Convert To") {
                ForEach(ConversionFormat.allCases) { format in
                    Button("\(format.name) Document") {
                        Task { await library.convert(live.filter(Library.canConvert), to: format) }
                    }
                }
            }
            .disabled(!live.contains(where: Library.canConvert))
            Button("Make Note from Highlights") { if let item = chosen.first { library.makeHighlightsNote(for: item) } }
                .disabled(chosen.count != 1 || (chosen.first?.highlights ?? []).isEmpty)
            Divider()
            Button("Check Feeds Now") { Task { await library.checkFeeds(all: true) } }
                .keyboardShortcut("u")
            Button("Indexed Folders…") { library.isManagingIndexedFolders = true }
            Button("Ask Your Library…") { library.isAskingLibrary = true }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Statistics") { library.isShowingStatistics = true }
            Button("Concordance") { library.isShowingConcordance = true }
            Button("New Notebook") { library.newNotebook() }
            Button("Link Graph") { library.isShowingGraph = true }
            Button("Smart Rules…") { library.isEditingRules = true }
        }
        CommandMenu("Library") {
            LibraryMenuItems(withShortcuts: true)
                .environment(library)
        }
        CommandMenu("Go") {
            Button("Back") { library.goBack() }
                .keyboardShortcut("[")
                .disabled(!library.canGoBack)
            Button("Forward") { library.goForward() }
                .keyboardShortcut("]")
                .disabled(!library.canGoForward)
            Divider()
            PlaceCommands(library: library)
            Divider()
            Button("Save Search as Smart Filter…") { library.isSavingSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(library.searchText.isEmpty && library.tagFilter.isEmpty)
            Button(library.isShowingTagFilter ? "Hide Tag Filter" : "Show Tag Filter") { library.isShowingTagFilter.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Save Workspace…") { library.isSavingWorkspace = true }
                .keyboardShortcut("s")
            WorkspaceMenu()
                .environment(library)
        }
    }
}
#endif

#if os(iOS)
/// Keyboard shortcuts on an iPad with a keyboard, in its menu bar.
struct PadCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { library.newNote() }
                .keyboardShortcut("n")
            Button("New Voice Note") { library.isRecording = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Today’s Note") { library.openToday() }
                .keyboardShortcut("0")
            Button("Add Link…") { library.isAddingLink = true }
                .keyboardShortcut("l")
            Button("Import Documents…") { library.isImporting = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Item") {
            let live = library.selectedItems.filter { !$0.isTrashed }
            let allFavorite = !live.isEmpty && live.allSatisfy(\.isFavorite)
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") { library.setFavorite(live, !allFavorite) }
                .keyboardShortcut("d")
                .disabled(live.isEmpty)
            let allQueued = !live.isEmpty && live.allSatisfy { $0.readLaterAt != nil }
            Button(allQueued ? "Remove from Read Later" : "Read Later") { library.setReadLater(live, !allQueued) }
                .keyboardShortcut("r")
                .disabled(live.isEmpty)
            let anyUnread = live.contains(where: \.isUnread)
            Button(anyUnread ? "Mark as Read" : "Mark as Unread") { library.setUnread(live, !anyUnread) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(live.isEmpty)
            Button("Add Tags…") { library.taggingItems = live }
                .keyboardShortcut("t")
                .disabled(live.isEmpty)
            Button("Move to Category…") { library.quickOpen = .file(live) }
                .keyboardShortcut("g")
                .disabled(live.isEmpty)
            Button("Copy Item Link") { if let item = live.first { library.copyItemLink(item) } }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(live.count != 1)
            Button("Print…") { library.printRequest = library.selection }
                .keyboardShortcut("p")
                .disabled(library.selection == nil)
            Divider()
            Button("Move to Trash") { library.moveToTrash(live) }
                .keyboardShortcut(.delete)
                .disabled(live.isEmpty)
            Divider()
            Button("Ask Your Library…") { library.isAskingLibrary = true }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Check Feeds Now") { Task { await library.checkFeeds(all: true) } }
                .keyboardShortcut("u")
        }
        CommandMenu("Go") {
            Button("Back") { library.goBack() }
                .keyboardShortcut("[")
                .disabled(!library.canGoBack)
            Button("Forward") { library.goForward() }
                .keyboardShortcut("]")
                .disabled(!library.canGoForward)
            Button("Quick Open…") { library.quickOpen = .open }
                .keyboardShortcut("o")
            Button("Command Palette…") { library.isShowingPalette = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            PlaceCommands(library: library)
            Divider()
            Button(library.isShowingTagFilter ? "Hide Tag Filter" : "Show Tag Filter") { library.isShowingTagFilter.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Save Workspace…") { library.isSavingWorkspace = true }
                .keyboardShortcut("s")
        }
    }
}
#endif

/// Cmd-1 to 9: the sidebar's places (Option-Cmd-1 to 9 switch libraries).
struct PlaceCommands: View {
    let library: Library

    static let places: [(String, SidebarSelection)] = [
        ("Inbox", .inbox), ("All Items", .all), ("Favorites", .favorites), ("Recents", .recents), ("Tasks", .tasks),
        ("Read Later", .readLater), ("Reminders", .reminders), ("Unfiled", .unfiled), ("Trash", .trash),
    ]

    var body: some View {
        ForEach(Array(Self.places.enumerated()), id: \.offset) { index, place in
            Button(place.0) { library.sidebar = place.1 }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
        }
    }
}
