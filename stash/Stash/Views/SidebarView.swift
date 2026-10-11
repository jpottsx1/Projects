import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Query(filter: #Predicate<ItemCategory> { $0.parent == nil }, sort: \ItemCategory.name)
    private var rootCategories: [ItemCategory]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \SmartFilter.name) private var smartFilters: [SmartFilter]
    @Query private var items: [Item]
    @State private var editingFilter: FilterEditing?

    private enum Naming {
        case new(parent: ItemCategory?)
        case rename(ItemCategory)
    }
    @State private var naming: Naming?
    @State private var nameDraft = ""

    var body: some View {
        @Bindable var library = library
        List(selection: $library.sidebar) {
            Section("Library") {
                Label("All Items", systemImage: "tray.full")
                    .tag(SidebarSelection.all)
                Label("Favorites", systemImage: "star")
                    .tag(SidebarSelection.favorites)
                ForEach(ItemKind.allCases) { kind in
                    Label(kind.pluralName, systemImage: kind.systemImage)
                        .tag(SidebarSelection.kind(kind))
                }
                let duplicateCount = library.duplicates(among: items).count
                if duplicateCount > 0 || library.sidebar == .duplicates {
                    Label("Duplicates", systemImage: "square.on.square")
                        .badge(duplicateCount)
                        .tag(SidebarSelection.duplicates)
                }
                Label("Trash", systemImage: "trash")
                    .tag(SidebarSelection.trash)
            }

            Section("Smart Filters") {
                ForEach(smartFilters) { filter in
                    Label(filter.name, systemImage: "line.3.horizontal.decrease.circle")
                        .tag(SidebarSelection.smartFilter(filter))
                        .help(filter.query)
                        .contextMenu {
                            Button("Edit…") { editingFilter = FilterEditing(filter: filter) }
                            Divider()
                            Button("Delete Smart Filter", role: .destructive) { library.delete(filter) }
                        }
                }
                Button {
                    editingFilter = FilterEditing(filter: nil)
                } label: {
                    Label("New Smart Filter", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section("Categories") {
                OutlineGroup(rootCategories, children: \.subcategories) { category in
                    Label(category.name, systemImage: "folder")
                        .tag(SidebarSelection.category(category))
                        .contextMenu {
                            Button("New Category Inside…") { startNaming(.new(parent: category)) }
                            Button("Rename…") { startNaming(.rename(category)) }
                            Divider()
                            Button("Delete Category", role: .destructive) { library.delete(category) }
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
        .navigationTitle("Stash")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if SyncMonitor.isEnabled { SyncStatusView() }
        }
        .sheet(item: $editingFilter) { editing in
            SmartFilterEditor(filter: editing.filter)
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { finishNaming() }
        }
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
    let id = UUID()
}
