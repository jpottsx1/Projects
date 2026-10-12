import SwiftUI
import SwiftData

/// The library, made once. Shortcuts can start the app without showing it,
/// so it can't wait for the window to be made.
@MainActor
final class StashStore {
    static let shared = StashStore()

    let container: ModelContainer
    let library: Library

    /// Launched with `-StashTestLibrary YES` (or `STASH_TEST_LIBRARY` set):
    /// a separate library to try things in, never synced, kept out of
    /// Spotlight, notifications and widgets, leaving the real one alone.
    static let isTestLibrary = UserDefaults.standard.bool(forKey: "StashTestLibrary")
        || ProcessInfo.processInfo.environment["STASH_TEST_LIBRARY"] != nil

    private init() {
        let schema = Schema([Item.self, Tag.self, ItemCategory.self, SmartFilter.self, Highlight.self, SmartRule.self, NoteVersion.self, NoteAttachment.self, Feed.self, IndexedFolder.self, Vault.self, ItemList.self, FieldDefinition.self])
        // Syncs through the iCloud container named in the entitlements,
        // which only exist when ICLOUD_SYNC is on (Config/Stash.xcconfig).
        // Said explicitly either way: left to itself SwiftData syncs
        // whenever it finds an iCloud entitlement.
        #if ICLOUD_SYNC
        var configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        #else
        var configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        #endif
        if Self.isTestLibrary {
            let folder = URL.applicationSupportDirectory.appendingPathComponent("StashTest", isDirectory: true)
            // UI tests start each run from nothing.
            if UserDefaults.standard.bool(forKey: "StashResetTestLibrary") {
                try? FileManager.default.removeItem(at: folder)
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("Library.store"),
                                               cloudKitDatabase: .none)
        }
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the library: \(error)")
        }
        library = Library(context: container.mainContext)
        // Choosing a reminder's notification opens its item.
        Reminders.shared.onOpen = { [library] id in
            if let item = library.items(withIDs: [id]).first { library.show(item) }
        }
        Reminders.shared.start()
    }
}

@main
struct StashApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(StashAppDelegate.self) private var appDelegate
    #else
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    #endif
    private let container: ModelContainer
    @State private var library: Library
    @State private var sync = SyncMonitor()

    init() {
        container = StashStore.shared.container
        _library = State(initialValue: StashStore.shared.library)
    }

    var body: some Scene {
        #if os(macOS)
        // One window: the library is one place, and a second window onto it
        // would only have to be kept in step with the first.
        Window("Stash", id: "main") {
            ContentView()
                .environment(library)
                .environment(sync)
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
                .environment(sync)
        }
        .modelContainer(container)
        .defaultSize(width: 860, height: 680)

        Window("Ask Your Library", id: "ask") {
            AskLibraryView(showsDone: false)
                .environment(library)
                .modelContainer(container)
        }
        .defaultSize(width: 560, height: 640)

        Window("Link Graph", id: "graph") {
            LinkGraphView()
                .environment(library)
                .modelContainer(container)
        }
        .defaultSize(width: 800, height: 600)
        #else
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(sync)
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(FeedRefresh.identifier)) {
            await FeedRefresh.run()
        }
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
            Button("Today’s Note") { library.openToday() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Voice Note") { library.isRecording = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Menu("New from Template") {
                // Read on every change of selection, which making a template is.
                let _ = library.selection
                TemplateMenuItems(library: library, templates: library.templates())
            }
            Divider()
            Button("Add Link…") { library.isAddingLink = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Subscribe to Feed…") { library.isAddingFeed = true }
            Button("Import Documents…") { library.isImporting = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Index Folder…") { library.isChoosingFolderToIndex = true }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { library.printRequest = windowItem ?? library.selection }
                .keyboardShortcut("p")
                .disabled(windowItem == nil && library.selection == nil)
            Button("Save as PDF…") { library.pdfRequest = windowItem ?? library.selection }
                .disabled(windowItem == nil && library.selection == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import from Evernote…") { library.isImportingEvernote = true }
            Button("Import Notes Folder…") { library.isImportingNotesFolder = true }
            Button("Import Mailbox…") { library.isImportingMailbox = true }
            Divider()
            Button(chosenItems.count > 1 ? "Export Items…" : "Export Item…") {
                let chosen = chosenItems
                let name = chosen.count == 1 ? chosen[0].displayTitle : "\(chosen.count) Items"
                library.exportRequest = .items(chosen, name: name)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(chosenItems.isEmpty)
            Button("Export Everything…") { library.exportRequest = .everything }
            Button("Export All Highlights…") { library.exportRequest = .highlights }
            Divider()
            Button("Restore from Backup…") { library.isRestoring = true }
        }
        CommandMenu("Item") {
            let chosen = chosenItems
            Button("Open in New Window") { for item in chosen { openWindow.item(item, asTab: false) } }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(chosen.isEmpty || windowItem != nil)
            Button("Open in New Tab") { for item in chosen { openWindow.item(item, asTab: true) } }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
                .disabled(chosen.isEmpty || windowItem != nil)
            Divider()
            let live = chosen.filter { !$0.isTrashed }
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
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(chosen.isEmpty)
            Button("Done (Take Out of Inbox)") { library.markFiled(chosen) }
                .disabled(!chosen.contains(where: \.inInbox))
            Button("Add Tags…") { library.taggingItems = live }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(live.isEmpty)
            Button("Remind Me…") { library.remindingItems = live }
                .disabled(live.isEmpty)
            let allQueued = !live.isEmpty && live.allSatisfy { $0.readLaterAt != nil }
            Button(allQueued ? "Remove from Read Later" : "Read Later") { library.setReadLater(live, !allQueued) }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(live.isEmpty)
            let allLocked = !live.isEmpty && live.allSatisfy(\.isLocked)
            Button(allLocked ? "Remove Lock…" : "Lock") {
                if allLocked { Task { await library.removeLock(from: live) } } else { library.lock(live) }
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(live.isEmpty)
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
            Button("Make Note from Highlights") { if let item = chosen.first { library.makeHighlightsNote(for: item) } }
                .disabled(chosen.count != 1 || (chosen.first?.highlights ?? []).isEmpty)
            Divider()
            Button("Check Feeds Now") { Task { await library.checkFeeds(all: true) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Indexed Folders…") { library.isManagingIndexedFolders = true }
            Button("Ask Your Library…") { library.isAskingLibrary = true }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Link Graph") { library.isShowingGraph = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Smart Rules…") { library.isEditingRules = true }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Back") { library.goBack() }
                .keyboardShortcut("[")
                .disabled(!library.canGoBack)
            Button("Forward") { library.goForward() }
                .keyboardShortcut("]")
                .disabled(!library.canGoForward)
        }
    }
}
#endif
