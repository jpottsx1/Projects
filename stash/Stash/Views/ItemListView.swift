import SwiftUI
import SwiftData
import StashCore

struct ItemListView: View {
    @Environment(Library.self) private var library
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var savingSearch: String?
    @State private var confirmingEmptyTrash = false
    @State private var confirmingDelete: [Item] = []

    var body: some View {
        @Bindable var library = library
        let items = library.visibleItems(from: allItems)
        List(selection: $library.selection) {
            ForEach(items) { item in
                ItemRow(item: item)
                    .tag(item)
                    .contextMenu { menu(for: item) }
                    .swipeActions(edge: .trailing) {
                        if item.isTrashed {
                            Button("Delete", role: .destructive) { confirmingDelete = [item] }
                            Button("Put Back") { library.restore([item]) }
                                .tint(.blue)
                        } else {
                            Button("Trash", role: .destructive) { library.moveToTrash([item]) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !item.isTrashed {
                            Button(item.isFavorite ? "Unfavorite" : "Favorite") {
                                library.setFavorite([item], !item.isFavorite)
                            }
                            .tint(.yellow)
                        }
                    }
            }
        }
        .overlay {
            if items.isEmpty { emptyState }
        }
        .navigationTitle(library.sidebarTitle)
        .searchable(text: $library.searchText, prompt: "Search, #tag, kind:pdf…")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AddMenu() }
            ToolbarItem {
                SortMenu()
            }
            if !library.searchText.isEmpty {
                ToolbarItem {
                    Button {
                        savingSearch = library.searchText
                    } label: {
                        Label("Save as Smart Filter", systemImage: "line.3.horizontal.decrease.circle.badge.plus")
                    }
                    .help("Save this search in the sidebar")
                }
            }
            if library.sidebar == .trash {
                ToolbarItem {
                    Button("Empty Trash", role: .destructive) { confirmingEmptyTrash = true }
                        .disabled(items.isEmpty)
                }
            }
        }
        // Files from Finder or Files become documents; web addresses become links.
        .dropDestination(for: URL.self) { urls, _ in
            library.add(urls)
            return !urls.isEmpty
        }
        #if os(macOS)
        .onDeleteCommand {
            guard let item = library.selection else { return }
            if item.isTrashed { confirmingDelete = [item] } else { library.moveToTrash([item]) }
        }
        #endif
        .sheet(item: Binding(get: { savingSearch.map(SearchDraft.init) }, set: { savingSearch = $0?.query })) { draft in
            SmartFilterEditor(filter: nil, query: draft.query) {
                library.searchText = ""
            }
        }
        .confirmationDialog("Delete everything in the Trash?", isPresented: $confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog(
            confirmingDelete.count == 1 ? "Delete “\(confirmingDelete[0].displayTitle)” immediately?" : "Delete these items immediately?",
            isPresented: Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) { library.deleteImmediately(confirmingDelete) }
        } message: {
            Text("This can’t be undone.")
        }
    }

    @ViewBuilder
    private func menu(for item: Item) -> some View {
        if item.isTrashed {
            Button("Put Back") { library.restore([item]) }
            Button("Delete Immediately…", role: .destructive) { confirmingDelete = [item] }
        } else {
            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                library.setFavorite([item], !item.isFavorite)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { library.moveToTrash([item]) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText)
        } else {
            switch library.sidebar ?? .all {
            case .trash:
                ContentUnavailableView("Trash Is Empty", systemImage: "trash",
                                       description: Text("Items stay here for \(Library.trashDays) days, then are deleted."))
            case .favorites:
                ContentUnavailableView("No Favorites", systemImage: "star",
                                       description: Text("Swipe an item, or use its menu, to add it to Favorites."))
            case .duplicates:
                ContentUnavailableView("No Duplicates", systemImage: "square.on.square",
                                       description: Text("Pages saved twice and files imported twice appear here."))
            case .smartFilter:
                ContentUnavailableView("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Nothing matches this smart filter yet."))
            default:
                ContentUnavailableView {
                    Label("Nothing Here Yet", systemImage: "tray")
                } description: {
                    Text("Add a note, save a link, or drop documents here.")
                }
            }
        }
    }
}

private struct SearchDraft: Identifiable {
    let query: String
    var id: String { query }
}

/// How the list is ordered. Search results are always best match first.
struct SortMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Menu {
            Picker("Sort By", selection: Binding(get: { library.sort }, set: { sort in
                library.sort = sort
                library.sortAscending = sort.naturallyAscending
            })) {
                ForEach(ItemSort.allCases) { sort in
                    Text(sort.name).tag(sort)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $library.sortAscending) {
                let natural = library.sort.naturallyAscending
                Text(library.sort.ascendingName(natural)).tag(natural)
                Text(library.sort.ascendingName(!natural)).tag(!natural)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort the list")
    }
}

struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(item.modifiedAt, format: .dateTime.day().month().year())
                    ForEach(item.sortedTags) { tag in
                        Text("#" + tag.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch item.kind {
        case .note:
            // The first couple of lines, without heading marks.
            return item.body
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(2)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                .joined(separator: " ")
        case .link:
            if !item.summary.isEmpty { return item.summary }
            return item.url.map { WebAddress.displayHost(of: $0) } ?? ""
        case .document:
            return item.contentType?.localizedDescription ?? ""
        }
    }
}
