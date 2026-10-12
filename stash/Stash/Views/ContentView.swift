import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

/// Three columns on a Mac or iPad -- sidebar, list, item. On an iPhone the
/// same three become screens you move between.
struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var tagDraft = ""
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            Group {
            if library.multiSelection.count > 1 {
                BulkEditView(items: library.selectedItems)
            } else if let item = library.selection {
                ItemDetailView(item: item)
                    .id(item.persistentModelID)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "tray",
                                       description: Text("Choose an item, or add a note, link or document."))
            }
            }
            #if os(macOS)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { library.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(!library.canGoBack)
                        .help("Back to the item before")
                    Button { library.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                        .disabled(!library.canGoForward)
                }
            }
            #endif
        }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .sheet(isPresented: $library.isAddingLink) {
            AddLinkSheet()
        }
        .modifier(LibrarySheets())
        // A widget's item or New Note.
        .onOpenURL { url in
            if url.scheme == Library.linkScheme { library.open(stashURL: url) }
        }
        // An item chosen in Spotlight.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:)),
                  let item = library.items(withIDs: [id]).first else { return }
            library.show(item)
        }
        // Things shared from other apps while Stash wasn't running.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.importSharedItems()
                library.checkFilesEditedElsewhere()
                Task {
                    await library.rescanIndexedFolders()
                    await library.checkFeeds()
                }
            } else {
                // Away from the app, locked items lock again.
                library.relockAll()
                #if os(iOS)
                if phase == .background { FeedRefresh.schedule() }
                #endif
            }
        }
        .alert("Can’t Lock", isPresented: Binding(get: { library.lockError != nil },
                                                  set: { if !$0 { library.lockError = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.lockError ?? "")
        }
        #if os(iOS)
        .onAppear { QuickActions.performPending() }
        #else
        // A Mac's scene phase doesn't follow the app in and out of the front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.checkFilesEditedElsewhere()
            Task { await library.checkFeeds() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            library.relockAll()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $library.isScanning) {
            DocumentScanner { pages in
                library.isScanning = false
                Task { await library.addScan(pages) }
            }
            .ignoresSafeArea()
        }
        #else
        // File › Import from iPhone or iPad: Continuity Camera's scans and photos.
        .importsItemProviders([.pdf, .image]) { providers in
            Task { await library.importProviders(providers) }
            return true
        }
        #endif
        .sheet(item: Binding(get: { library.remindingItems.map(ItemGroup.init) },
                             set: { library.remindingItems = $0?.items })) { group in
            ReminderPicker(items: group.items)
        }
        .alert("Add Tags", isPresented: Binding(get: { library.taggingItems != nil },
                                                set: { if !$0 { library.taggingItems = nil } })) {
            TextField("Tags, separated by commas", text: $tagDraft)
            Button("Cancel", role: .cancel) { tagDraft = "" }
            Button("Add") {
                library.addTags(from: tagDraft, to: library.taggingItems ?? [])
                tagDraft = ""
            }
        } message: {
            Text("They’re added to \(library.taggingItems?.count ?? 0) items.")
        }
        .sheet(item: $library.viewingHistoryOf) { item in
            NoteHistoryView(item: item)
        }
        #if os(iOS)
        .sheet(isPresented: $library.isShowingGraph) {
            LinkGraphView()
        }
        .sheet(isPresented: $library.isAskingLibrary) {
            AskLibraryView()
        }
        #else
        .onChange(of: library.isAskingLibrary) {
            guard library.isAskingLibrary else { return }
            library.isAskingLibrary = false
            openWindow(id: "ask")
        }
        // On a Mac the graph has a window of its own.
        .onChange(of: library.isShowingGraph) {
            guard library.isShowingGraph else { return }
            library.isShowingGraph = false
            openWindow(id: "graph")
        }
        #endif
        .sheet(isPresented: $library.isEditingRules) {
            RulesView()
        }
        .sheet(item: $library.editingHighlight) { highlight in
            HighlightNoteEditor(highlight: highlight)
        }
        // Export and restore live on a view of their own: SwiftUI shows one
        // file panel per view, and the documents importer has this one.
        .background { BackupPanels() }
        .background { PrintPanels() }
        .background { ImportPanels() }
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
            Button { library.openToday() } label: {
                Label("Today’s Note", systemImage: "calendar")
            }
            Button { library.isRecording = true } label: {
                Label("New Voice Note", systemImage: "mic")
            }
            Menu {
                TemplateMenuItems(library: library, templates: library.templates())
            } label: {
                Label("New from Template", systemImage: "doc.on.doc")
            }
            Button { library.isAddingLink = true } label: {
                Label("Add Link…", systemImage: "link.badge.plus")
            }
            Button { library.isImporting = true } label: {
                Label("Import Documents…", systemImage: "doc.badge.plus")
            }
            Button { library.isAddingFeed = true } label: {
                Label("Subscribe to Feed…", systemImage: "dot.radiowaves.up.forward")
            }
            #if os(iOS)
            if DocumentScanner.isAvailable {
                Button { library.isScanning = true } label: {
                    Label("Scan Documents", systemImage: "doc.viewfinder")
                }
            }
            #endif
        } label: {
            Label("Add", systemImage: "plus")
        }
    }
}

/// Exporting (with progress, then the save panel) and restoring.
private struct BackupPanels: View {
    @Environment(Library.self) private var library
    /// The finished export, waiting to be moved where it's wanted.
    @State private var exported: URL?
    @State private var isWorking = false
    @State private var message: (title: String, text: String)?

    var body: some View {
        @Bindable var library = library
        Color.clear
            .onChange(of: library.exportRequest?.id) {
                guard let request = library.exportRequest else { return }
                library.exportRequest = nil
                Task { await export(request) }
            }
            // Moved rather than exported: a backup can be large, and the
            // file is already made. (Exporting a Transferable file crashed
            // in SwiftUI on iOS 26.)
            .fileMover(isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }),
                       file: exported) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    message = ("Couldn’t Export", error.localizedDescription)
                }
            }
            .fileImporter(isPresented: $library.isRestoring, allowedContentTypes: [.zip]) { result in
                guard case .success(let url) = result else { return }
                Task { await restore(url) }
            }
            .overlay {
                if isWorking {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: {
                Text(message?.text ?? "")
            }
    }

    private func export(_ request: ExportRequest) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch request {
            case .items(let items, let name):
                exported = try await library.export(items, everything: false, named: name)
            case .everything:
                exported = try await library.exportEverything()
            case .highlights:
                exported = try library.exportHighlights()
            }
        } catch {
            message = ("Couldn’t Export", error.localizedDescription)
        }
    }

    private func restore(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let summary = try await library.restore(from: url)
            var text = summary.added == 1 ? "1 item was added." : "\(summary.added) items were added."
            if summary.skipped > 0 {
                text += summary.skipped == 1 ? " 1 was already in the library." : " \(summary.skipped) were already in the library."
            }
            message = ("Restored", text)
        } catch {
            message = ("Couldn’t Restore", error.localizedDescription)
        }
    }
}

/// Items to present a sheet about.
struct ItemGroup: Identifiable {
    let items: [Item]
    var id: String { items.map(\.uuid.uuidString).joined() }
}

/// Printing, and saving as PDF with the save panel.
private struct PrintPanels: View {
    @Environment(Library.self) private var library
    @State private var printer = ItemPrinter()
    @State private var pdf: URL?
    @State private var isWorking = false

    var body: some View {
        Color.clear
            .onChange(of: library.printRequest) {
                guard let item = library.printRequest else { return }
                library.printRequest = nil
                Task { await printer.print(item, in: library) }
            }
            .onChange(of: library.pdfRequest) {
                guard let item = library.pdfRequest else { return }
                library.pdfRequest = nil
                Task {
                    isWorking = true
                    pdf = await printer.pdf(of: item, in: library)
                    isWorking = false
                }
            }
            .fileMover(isPresented: Binding(get: { pdf != nil }, set: { if !$0 { pdf = nil } }), file: pdf) { _ in }
            .overlay {
                if isWorking {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }
}

/// Sheets the library asks for from anywhere: kept apart from
/// `ContentView`'s own, which were more than the compiler could check at once.
private struct LibrarySheets: ViewModifier {
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        @Bindable var library = library
        content
        .sheet(isPresented: $library.isAddingFeed) {
            AddFeedSheet()
        }
        .sheet(isPresented: $library.isManagingIndexedFolders) {
            IndexedFoldersView()
        }
        .sheet(isPresented: $library.isRecording) {
            RecordingSheet()
        }
        .sheet(item: $library.passwordRequest) { request in
            PasswordSheet(request: request)
        }
        .modifier(NewListPrompt())
        .sheet(item: Binding(get: { library.renamingItems.map(ItemGroup.init) },
                             set: { library.renamingItems = $0?.items })) { group in
            BatchRenameView(items: group.items)
        }
    }
}
