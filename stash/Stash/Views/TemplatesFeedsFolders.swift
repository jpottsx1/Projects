import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import StashCore

// MARK: - Templates

/// Over a template: what it is, and a way to use it.
struct TemplateBanner: View {
    @Environment(Library.self) private var library
    let item: Item

    var body: some View {
        let isDaily = library.dailyTemplate == item
        HStack {
            Label("Template", systemImage: "doc.on.doc")
                .font(.callout.weight(.medium))
            #if os(macOS)
            Text("{{date}}, {{time}}, {{title}} and {{clipboard}} are filled in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Also {{weekday}}, {{yesterday}}, {{tomorrow}}, {{events}} (the day’s calendar), and {{date:EEEE d MMMM}} in any date format.")
            #endif
            Spacer()
            Toggle("Daily Note", isOn: Binding(get: { isDaily }, set: { library.dailyTemplate = $0 ? item : nil }))
                .help("Make each day’s note from this template")
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .fixedSize()
            Button("New Note") { library.newNote(from: item) }
                .accessibilityIdentifier("newNoteFromTemplate")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.purple.opacity(0.12))
    }
}

/// A button for each template, to make a note from it.
struct TemplateMenuItems: View {
    let library: Library
    let templates: [Item]

    var body: some View {
        if templates.isEmpty {
            Button("No Templates Yet") {}
                .disabled(true)
        }
        ForEach(templates) { template in
            Button(template.displayTitle) { library.newNote(from: template) }
        }
        Divider()
        Button("Show Templates") { library.sidebar = .templates }
    }
}

// MARK: - Feeds

/// Subscribing to a feed, by its address or its site's.
struct AddFeedSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Site or feed address", text: $address)
                    .focused($focused)
                    .onSubmit(subscribe)
                    .accessibilityIdentifier("feedAddress")
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text("New posts arrive unread under the feed in the sidebar, and are saved like any link to read offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Subscribe to Feed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Subscribe", action: subscribe)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .sheetSize(minWidth: 420, minHeight: 220)
        .onAppear {
            // A web address on the clipboard is probably the one wanted.
            if let copied = Library.clipboardText(), WebAddress.url(from: copied) != nil, !copied.contains(" ") {
                address = copied
            }
            focused = true
        }
    }

    private func subscribe() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await library.subscribe(to: address)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// The Feeds part of the sidebar.
struct FeedsSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    @State private var renaming: Feed?
    @State private var nameDraft = ""
    @State private var unsubscribing: Feed?

    var body: some View {
        Section("Feeds") {
            ForEach(feeds) { feed in
                HStack {
                    Label(feed.title.isEmpty ? feed.urlString : feed.title, systemImage: "dot.radiowaves.up.forward")
                    if library.checkingFeeds.contains(feed.uuid) {
                        Spacer()
                        ProgressView().controlSize(.mini)
                    } else if !feed.lastError.isEmpty {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(feed.lastError)
                    }
                }
                .badge((feed.items ?? []).filter { $0.isUnread && !$0.isTrashed }.count)
                .tag(SidebarSelection.feed(feed))
                .help(feed.lastError.isEmpty ? feed.urlString : feed.lastError)
                .contextMenu {
                    Button("Check Now") { Task { await library.check(feed) } }
                    Button("Mark All as Read") { library.markAllRead(in: feed) }
                    Button("Rename…") {
                        nameDraft = feed.title
                        renaming = feed
                    }
                    Menu("File New Posts In") {
                        Button("Nowhere") { library.file(feed, in: nil) }
                        Divider()
                        ForEach(categories.filter { $0.parent == nil }.flatMap(\.flattened)) { category in
                            Button(category.path) { library.file(feed, in: category) }
                        }
                    }
                    if let site = feed.siteURLString.flatMap(URL.init(string:)) {
                        Link("Open Website", destination: site)
                    }
                    Divider()
                    Button("Unsubscribe…", role: .destructive) { unsubscribing = feed }
                }
            }
            // The dialogs hang off this button: a sidebar section can't show them.
            Button {
                library.isAddingFeed = true
            } label: {
                Label("Subscribe to Feed", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .modifier(FeedDialogs(renaming: $renaming, nameDraft: $nameDraft, unsubscribing: $unsubscribing))
        }
    }
}

private struct FeedDialogs: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var renaming: Feed?
    @Binding var nameDraft: String
    @Binding var unsubscribing: Feed?

    func body(content: Content) -> some View {
        content
        .alert("Rename Feed", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let renaming { library.rename(renaming, to: nameDraft) } }
        }
        .confirmationDialog("Unsubscribe from “\(unsubscribing?.title ?? "")”?",
                            isPresented: Binding(get: { unsubscribing != nil }, set: { if !$0 { unsubscribing = nil } })) {
            Button("Unsubscribe", role: .destructive) {
                if let unsubscribing { library.unsubscribe(unsubscribing) }
            }
        } message: {
            Text("Posts you’ve read or kept notes on stay in the library. Unread ones go to the Trash.")
        }
    }
}

/// How often feeds are checked.
struct FeedIntervalPicker: View {
    @AppStorage("feedCheckMinutes") private var minutes = 60

    var body: some View {
        Picker("Check Feeds Every", selection: $minutes) {
            Text("15 Minutes").tag(15)
            Text("30 Minutes").tag(30)
            Text("Hour").tag(60)
            Text("3 Hours").tag(180)
            Text("Day").tag(1440)
        }
        // A submenu where it's in a menu, rather than five items in a row.
        .pickerStyle(.menu)
    }
}

// MARK: - Indexed folders

/// The folders being indexed, and adding and removing them.
struct IndexedFoldersView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IndexedFolder.name) private var folders: [IndexedFolder]
    @State private var removing: IndexedFolder?

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    ContentUnavailableView("No Indexed Folders", systemImage: "folder.badge.gearshape",
                                           description: Text("Index a folder to see its documents in Stash while the files stay where they are. Changes made there are followed."))
                }
                ForEach(folders) { folder in
                    row(folder)
                }
            }
            .navigationTitle("Indexed Folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        library.isChoosingFolderToIndex = true
                    } label: {
                        Label("Index Folder…", systemImage: "plus")
                    }
                }
            }
        }
        .sheetSize(minWidth: 520, minHeight: 320)
        .confirmationDialog("Stop indexing “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Stop Indexing", role: .destructive) {
                if let removing { library.removeIndexedFolder(removing) }
            }
        } message: {
            Text("Its documents leave Stash, along with any notes, tags and highlights added to them here. The files themselves stay where they are.")
        }
    }

    private func row(_ folder: IndexedFolder) -> some View {
        let here = library.isHere(folder)
        let count = (folder.items ?? []).filter { !$0.isTrashed }.count
        return HStack {
            Image(systemName: here ? "folder" : "folder.badge.questionmark")
                .foregroundStyle(here ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.headline)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(here ? "\(count) documents" + (folder.lastScannedAt.map { " · checked \($0.formatted(.relative(presentation: .named)))" } ?? "")
                     : "On \(folder.deviceName.isEmpty ? "another device" : folder.deviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if library.scanningFolders.contains(folder.uuid) {
                ProgressView().controlSize(.small)
            } else if here {
                Button("Check Now") { Task { await library.rescan(folder) } }
                    .buttonStyle(.borderless)
            }
            Button(role: .destructive) {
                removing = folder
            } label: {
                Label("Stop Indexing", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Stop indexing this folder")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Import panels

/// The open panels for importing notes and indexing folders, each on a
/// view of its own (SwiftUI shows one file panel per view), and what came
/// of them.
struct ImportPanels: View {
    @Environment(Library.self) private var library
    @State private var summary: ImportSummary?
    @State private var isWorking = false

    static let enex = UTType(filenameExtension: "enex", conformingTo: .xml) ?? .xml
    static let mbox = UTType(filenameExtension: "mbox", conformingTo: .data) ?? .data

    var body: some View {
        @Bindable var library = library
        ZStack {
            Color.clear
                .fileImporter(isPresented: $library.isImportingEvernote, allowedContentTypes: [Self.enex, .xml],
                              allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result, !urls.isEmpty else { return }
                    run { await library.importEvernote(urls) }
                }
            Color.clear
                .fileImporter(isPresented: $library.isImportingNotesFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    run { await library.importNotes(from: url) }
                }
            Color.clear
                .fileImporter(isPresented: $library.isImportingMailbox, allowedContentTypes: [Self.mbox, .folder, .data]) { result in
                    guard case .success(let url) = result else { return }
                    run { await library.importMailbox(url) }
                }
            Color.clear
                .fileImporter(isPresented: $library.isChoosingFolderToIndex, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    library.isManagingIndexedFolders = false
                    Task { await library.index(folder: url) }
                }
        }
        .sheet(isPresented: $isWorking) {
            VStack(spacing: 12) {
                ProgressView()
                Text("Importing…")
            }
            .padding(32)
            .interactiveDismissDisabled()
        }
        .alert("Import Finished", isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
            Button("OK") {}
        } message: {
            Text(summary?.message ?? "")
        }
    }

    private func run(_ work: @escaping () async -> ImportSummary) {
        isWorking = true
        Task {
            let result = await work()
            isWorking = false
            // The alert waits for the sheet to go.
            try? await Task.sleep(for: .milliseconds(400))
            summary = result
        }
    }
}
