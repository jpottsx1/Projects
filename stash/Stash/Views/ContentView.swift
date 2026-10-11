import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

/// Three columns on a Mac or iPad -- sidebar, list, item. On an iPhone the
/// same three become screens you move between.
struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let item = library.selection {
                ItemDetailView(item: item)
                    .id(item.persistentModelID)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "tray",
                                       description: Text("Choose an item, or add a note, link or document."))
            }
        }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .sheet(isPresented: $library.isAddingLink) {
            AddLinkSheet()
        }
        // An item chosen in Spotlight.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:)),
                  let item = library.items(withIDs: [id]).first else { return }
            library.show(item)
        }
        // Things shared from other apps while Stash wasn't running.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.importSharedItems() }
        }
        .alert("Couldn’t Import", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(library.importError ?? "")
        }
    }
}

/// The + button: the three ways in.
struct AddMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        Menu {
            Button { library.newNote() } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            Button { library.isAddingLink = true } label: {
                Label("Add Link…", systemImage: "link.badge.plus")
            }
            Button { library.isImporting = true } label: {
                Label("Import Documents…", systemImage: "doc.badge.plus")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }
}
