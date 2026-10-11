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
        let schema = Schema([Item.self, Tag.self, ItemCategory.self, SmartFilter.self, Highlight.self, SmartRule.self])
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
    }
}

@main
struct StashApp: App {
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
            Button("Export Item…") {
                if let item = library.selection { library.exportRequest = .items([item], name: item.displayTitle) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(library.selection == nil)
            Button("Export Everything…") { library.exportRequest = .everything }
            Divider()
            Button("Restore from Backup…") { library.isRestoring = true }
        }
        CommandMenu("Item") {
            Button(library.selection?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let item = library.selection { library.setFavorite([item], !item.isFavorite) }
            }
            .keyboardShortcut("d")
            .disabled(library.selection == nil || library.selection?.isTrashed == true)
            Button(library.selection?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
                if let item = library.selection { library.setUnread([item], !item.isUnread) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(library.selection == nil)
            Button("Done (Take Out of Inbox)") {
                if let item = library.selection { library.markFiled([item]) }
            }
            .disabled(library.selection?.inInbox != true)
            Divider()
            Button("Move to Trash") {
                if let item = library.selection { library.moveToTrash([item]) }
            }
            .keyboardShortcut(.delete)
            .disabled(library.selection == nil || library.selection?.isTrashed == true)
            Button("Put Back") {
                if let item = library.selection { library.restore([item]) }
            }
            .disabled(library.selection?.isTrashed != true)
            Divider()
            Button("Smart Rules…") { library.isEditingRules = true }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}
#endif
