import SwiftUI
import SwiftData

/// The library, made once. Shortcuts can start the app without showing it,
/// so it can't wait for the window to be made.
@MainActor
final class StashStore {
    static let shared = StashStore()

    let container: ModelContainer
    let library: Library

    private init() {
        let schema = Schema([Item.self, Tag.self, ItemCategory.self, SmartFilter.self, Highlight.self, SmartRule.self, NoteVersion.self])
        // Syncs through the iCloud container named in the entitlements,
        // which only exist when ICLOUD_SYNC is on (Config/Stash.xcconfig).
        // Said explicitly either way: left to itself SwiftData syncs
        // whenever it finds an iCloud entitlement.
        #if ICLOUD_SYNC
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        #else
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        #endif
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
        #else
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(sync)
        }
        .modelContainer(container)
        #endif
    }
}

#if os(macOS)
struct StashCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { library.newNote() }
                .keyboardShortcut("n")
            Button("Add Link…") { library.isAddingLink = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Import Documents…") { library.isImporting = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Button(library.selectedItems.count > 1 ? "Export Items…" : "Export Item…") {
                let chosen = library.selectedItems
                let name = chosen.count == 1 ? chosen[0].displayTitle : "\(chosen.count) Items"
                library.exportRequest = .items(chosen, name: name)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(library.selectedItems.isEmpty)
            Button("Export Everything…") { library.exportRequest = .everything }
            Divider()
            Button("Restore from Backup…") { library.isRestoring = true }
        }
        CommandMenu("Item") {
            let chosen = library.selectedItems
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
            Divider()
            Button("Move to Trash") { library.moveToTrash(live) }
                .keyboardShortcut(.delete)
                .disabled(live.isEmpty)
            Button("Put Back") { library.restore(chosen.filter(\.isTrashed)) }
                .disabled(!chosen.contains(where: \.isTrashed))
            Divider()
            Button("Smart Rules…") { library.isEditingRules = true }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}
#endif
