import SwiftUI
import SwiftData

@main
struct StashApp: App {
    private let container: ModelContainer
    @State private var library: Library
    @State private var sync = SyncMonitor()

    init() {
        let schema = Schema([Item.self, Tag.self, ItemCategory.self])
        // Syncs through the iCloud container named in the entitlements,
        // which only exist when ICLOUD_SYNC is on (Config/Stash.xcconfig).
        // Said explicitly either way: left to itself SwiftData syncs
        // whenever it finds an iCloud entitlement.
        #if ICLOUD_SYNC
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        #else
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        #endif
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the library: \(error)")
        }
        self.container = container
        _library = State(initialValue: Library(context: container.mainContext))
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
        .commands { StashCommands(library: library) }
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
    }
}
#endif
