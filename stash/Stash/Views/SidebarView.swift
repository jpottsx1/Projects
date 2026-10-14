import SwiftUI
import SwiftData
import StashCore

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Query(filter: #Predicate<ItemCategory> { $0.parent == nil }, sort: \ItemCategory.name)
    private var rootCategories: [ItemCategory]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \SmartFilter.name) private var smartFilters: [SmartFilter]
    @State private var editingFilter: FilterEditing?
    @Query private var allCategories: [ItemCategory]

    private enum Naming {
        case new(parent: ItemCategory?)
        case rename(ItemCategory)
    }
    @State private var naming: Naming?
    @State private var nameDraft = ""

    var body: some View {
        @Bindable var library = library
        // Counted by the store and kept until the next save: loading every
        // item to count them made a big library slow to draw.
        let _ = library.storeVersion
        let counts = library.sidebarCounts()
        List(selection: $library.sidebar) {
            Section("Library") {
                Label("Inbox", systemImage: "tray.and.arrow.down")
                    .badge(counts.inbox)
                    .tag(SidebarSelection.inbox)
                Label("All Items", systemImage: "tray.full")
                    .tag(SidebarSelection.all)
                Label("Favorites", systemImage: "star")
                    .tag(SidebarSelection.favorites)
                Label("Recents", systemImage: "clock")
                    .tag(SidebarSelection.recents)
                Label("Unfiled", systemImage: "questionmark.folder")
                    .tag(SidebarSelection.unfiled)
                Label("Reminders", systemImage: "bell")
                    .badge(counts.due)
                    .tag(SidebarSelection.reminders)
                Label("Read Later", systemImage: "book")
                    .badge(counts.readLater)
                    .tag(SidebarSelection.readLater)
                Label("Timeline", systemImage: "calendar")
                    .tag(SidebarSelection.timeline)
                ForEach(ItemKind.allCases) { kind in
                    Label(kind.pluralName, systemImage: kind.systemImage)
                        .tag(SidebarSelection.kind(kind))
                }
                let duplicateCount = counts.duplicates
                if duplicateCount > 0 || library.sidebar == .duplicates {
                    Label("Duplicates", systemImage: "square.on.square")
                        .badge(duplicateCount)
                        .tag(SidebarSelection.duplicates)
                }
                Label("Templates", systemImage: "doc.on.doc")
                    .tag(SidebarSelection.templates)
                Label("Trash", systemImage: "trash")
                    .tag(SidebarSelection.trash)
            }

            FeedsSection()

            ListsSection { filter in editingFilter = FilterEditing(filter: filter) } newFilter: { scope in
                editingFilter = FilterEditing(filter: nil, scope: scope)
            }

            Section("Smart Filters") {
                ForEach(orderedSmartFilters.filter { $0.scope == .library }) { filter in
                    filterRow(filter)
                }
                .onMove { library.moveSmartFilters(from: $0, to: $1) }
                Button {
                    editingFilter = FilterEditing(filter: nil, scope: .library)
                } label: {
                    Label("New Smart Filter", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section("Categories") {
                let destination = allCategories.filter(\.isImportDestination).min { $0.uuid.uuidString < $1.uuid.uuidString }
                OutlineGroup(CategoryNode.nodes(rootCategories.sorted(by: ItemCategory.inOrder)), children: \.children) { node in
                    switch node.content {
                    case .filter(let filter):
                        filterRow(filter)
                    case .category(let category):
                        categoryRow(category, isDestination: category == destination)
                    }
                }
                Button {
                    startNaming(.new(parent: nil))
                } label: {
                    Label("New Category", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section("Tags") {
                if tags.isEmpty {
                    Text("Tags you add to items appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(tags) { tag in
                    Label(tag.name, systemImage: "number")
                        .badge((tag.items ?? []).filter { !$0.isTrashed }.count)
                        .tag(SidebarSelection.tag(tag))
                        .contextMenu {
                            Button("Delete Tag", role: .destructive) { library.delete(tag) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(sidebarTitle)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Quick Open…") { library.quickOpen = .open }
                    Menu("Library") { LibraryMenuItems() }
                    Divider()
                    Button("Today’s Note") { library.openToday() }
                    Button("Note for Event…") { library.eventPicking = .newNote }
                    DailyEventsToggle()
                    AutoLinkToggle()
                    Button("New Voice Note") { library.isRecording = true }
                    Button("Ask Your Library…") { library.isAskingLibrary = true }
                    Button("Statistics") { library.isShowingStatistics = true }
                    Button("Concordance") { library.isShowingConcordance = true }
                    Button("Link Graph") { library.isShowingGraph = true }
                    Button("Smart Rules…") { library.isEditingRules = true }
                    Divider()
                    Button("Subscribe to Feed…") { library.isAddingFeed = true }
                    Button("Check Feeds Now") { Task { await library.checkFeeds(all: true) } }
                    FeedIntervalPicker()
                    Divider()
                    Button("Index Folder…") { library.isChoosingFolderToIndex = true }
                    Button("Indexed Folders…") { library.isManagingIndexedFolders = true }
                    Divider()
                    Button("Import from Evernote…") { library.isImportingEvernote = true }
                    Button("Import Notes Folder…") { library.isImportingNotesFolder = true }
                    Button("Import Mailbox…") { library.isImportingMailbox = true }
                    Button("Import Bookmarks…") { library.isImportingBookmarks = true }
                    Button("Export All Highlights…") { library.exportRequest = .highlights }
                    Button("Export Everything…") { library.exportRequest = .everything }
                    Button("Restore from Backup…") { library.isRestoring = true }
                    if StashStore.isTestLibrary {
                        Divider()
                        Button("Add 10,000 Test Items") { library.generateTestItems(10_000) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Daily notes, feeds, folders, import and export")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if SyncMonitor.isEnabled { SyncStatusView() }
        }
        .sheet(item: $editingFilter) { editing in
            SmartFilterEditor(filter: editing.filter, scope: editing.scope)
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { finishNaming() }
        }
    }

    private func filterRow(_ filter: SmartFilter) -> some View {
        Label(filter.name, systemImage: "line.3.horizontal.decrease.circle")
            .tag(SidebarSelection.smartFilter(filter))
            .help(filter.query)
            .contextMenu {
                Button("Edit…") { editingFilter = FilterEditing(filter: filter) }
                Button("Duplicate") { library.duplicate(filter) }
                Divider()
                Button("Delete Smart Filter", role: .destructive) { library.delete(filter) }
            }
    }

    private func categoryRow(_ category: ItemCategory, isDestination: Bool) -> some View {
        Label {
            HStack {
                Text(category.name)
                if isDestination {
                    Spacer()
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .help("New things arrive here instead of the Inbox")
                }
            }
        } icon: {
            Image(systemName: category.colorRaw == 0 ? "folder" : "folder.fill")
                .foregroundStyle(folderColor(category))
        }
        .tag(SidebarSelection.category(category))
        .contextMenu {
            Button("New Category Inside…") { startNaming(.new(parent: category)) }
            Button("New Smart Filter Here…") { editingFilter = FilterEditing(filter: nil, scope: .category(category)) }
            Button(isDestination ? "Stop Using as Import Destination" : "Use as Import Destination") {
                library.setImportDestination(isDestination ? nil : category)
            }
            .help("New things with no category arrive here instead of the Inbox")
            Button("Rename…") { startNaming(.rename(category)) }
            Menu("Color") {
                ForEach(ItemLabel.allCases) { label in
                    Button(label == .none ? "None" : label.name) { library.setColor(label, of: category) }
                }
            }
            Button("Move Up") { library.move(category, by: -1) }
            Button("Move Down") { library.move(category, by: 1) }
            Button("Duplicate") { library.duplicate(category) }
            Button("Export…") {
                let inside = library.items(in: category)
                library.exportRequest = .items(inside, name: category.name)
            }
            Divider()
            Button("Delete Category", role: .destructive) { library.delete(category) }
        }
    }

    /// Smart filters in the order they've been dragged into, then by name.
    private var orderedSmartFilters: [SmartFilter] {
        smartFilters.sorted { a, b in
            a.order != b.order ? a.order < b.order : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The colour a category's folder is shown in.
    private func folderColor(_ category: ItemCategory) -> Color {
        category.colorRaw == 0 ? .accentColor : (ItemLabel(rawValue: category.colorRaw) ?? .none).color
    }

    /// The open library's name; "Stash" when there's only the one.
    private var sidebarTitle: String {
        let store = StashStore.shared
        let name = store.libraries.count > 1 ? store.current.name : "Stash"
        return StashStore.isTestLibrary ? name + " (Test Library)" : name
    }

    private var namingTitle: String {
        switch naming {
        case .rename: "Rename Category"
        case .new(let parent?): "New Category in “\(parent.name)”"
        default: "New Category"
        }
    }

    private func startNaming(_ mode: Naming) {
        if case .rename(let category) = mode { nameDraft = category.name } else { nameDraft = "" }
        naming = mode
    }

    private func finishNaming() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch naming {
        case .new(let parent):
            if let category = library.newCategory(named: name, in: parent) {
                library.sidebar = .category(category)
            }
        case .rename(let category):
            library.rename(category, to: name)
        case nil:
            break
        }
        naming = nil
    }
}

private struct FilterEditing: Identifiable {
    let filter: SmartFilter?
    var scope: SmartFilterScope?
    let id = UUID()
}

/// A row in the categories' outline: a category, or a smart filter
/// searching in it, shown inside it.
private struct CategoryNode: Identifiable {
    enum Content: Hashable {
        case category(ItemCategory)
        case filter(SmartFilter)
    }

    let content: Content
    let children: [CategoryNode]?
    var id: Content { content }

    static func nodes(_ categories: [ItemCategory]) -> [CategoryNode] {
        categories.map { category in
            let filters = (category.smartFilters ?? [])
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { CategoryNode(content: .filter($0), children: nil) }
            let inside = filters + nodes(category.subcategories ?? [])
            return CategoryNode(content: .category(category), children: inside.isEmpty ? nil : inside)
        }
    }
}
