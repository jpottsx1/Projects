import SwiftUI
import SwiftData
import StashCore

struct ItemListView: View {
    @Environment(Library.self) private var library
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var savingSearch: String?
    @State private var confirmingEmptyTrash = false
    @State private var confirmingDelete: [Item] = []
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var library = library
        let items = library.visibleItems(from: allItems)
        Group {
            if library.showsGrid && sizeClass != .compact {
                grid(items)
            } else {
                list(items)
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
            if sizeClass != .compact {
                ToolbarItem {
                    Picker("View", selection: $library.showsGrid) {
                        Label("List", systemImage: "list.bullet").tag(false)
                        Label("Grid", systemImage: "square.grid.2x2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Show as a list or as a grid")
                }
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

    private func list(_ items: [Item]) -> some View {
        @Bindable var library = library
        return List(selection: $library.selection) {
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
    }

    /// Cards with pictures, for a wide window.
    private func grid(_ items: [Item]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 14) {
                ForEach(items) { item in
                    ItemCard(item: item, isSelected: library.selection == item)
                        .onTapGesture { library.selection = item }
                        .contextMenu { menu(for: item) }
                }
            }
            .padding()
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
            Button(item.isUnread ? "Mark as Read" : "Mark as Unread") {
                library.setUnread([item], !item.isUnread)
            }
            if item.inInbox {
                Button("Done (Take Out of Inbox)") { library.markFiled([item]) }
            }
            LabelAndRatingMenus(items: [item])
            Divider()
            Button("Export…") { library.exportRequest = .items([item], name: item.displayTitle) }
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
            case .inbox:
                ContentUnavailableView("Inbox Is Empty", systemImage: "tray.and.arrow.down",
                                       description: Text("Pages, files and things shared from other apps wait here until you give them a category."))
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
            Group {
                if item.thumbnailData != nil {
                    ThumbnailImage(item: item)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                } else {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                }
            }
                .overlay(alignment: .topLeading) {
                    if item.isUnread {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .offset(x: -8, y: -2)
                            .accessibilityLabel("Unread")
                    }
                }
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
                    if item.label != .none {
                        Circle()
                            .fill(item.label.color)
                            .frame(width: 9, height: 9)
                            .accessibilityLabel("\(item.label.name) label")
                    }
                }
                if !item.listSubtitle.isEmpty {
                    Text(item.listSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if item.rating > 0 {
                        Text(String(repeating: "★", count: item.rating))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(item.rating) stars")
                    }
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

}

/// Label and Rating submenus, for an item's context menu.
struct LabelAndRatingMenus: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        Menu("Label") {
            ForEach(ItemLabel.allCases) { label in
                Button {
                    library.setLabel(items, label)
                } label: {
                    if label == .none {
                        Text("None")
                    } else {
                        Label(label.name, systemImage: items.allSatisfy { $0.label == label } ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                .tint(label.color)
            }
        }
        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    library.setRating(items, stars)
                }
            }
        }
    }
}

extension ItemLabel {
    var color: Color {
        switch self {
        case .none: .clear
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

extension Item {
    /// A line or two under the title: a note's opening, a page's summary, a file's type.
    var listSubtitle: String {
        switch kind {
        case .note:
            // The first couple of lines, without heading marks.
            return body
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(2)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                .joined(separator: " ")
        case .link:
            if !summary.isEmpty { return summary }
            return url.map { WebAddress.displayHost(of: $0) } ?? ""
        case .document:
            return contentType?.localizedDescription ?? ""
        }
    }
}

/// An item as a card in the grid: its picture (or a note's opening), title and details.
struct ItemCard: View {
    let item: Item
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .overlay(alignment: .topTrailing) { badges.padding(6) }
                .overlay(alignment: .topLeading) {
                    if item.isUnread {
                        Circle().fill(.blue).frame(width: 9, height: 9).padding(7)
                            .accessibilityLabel("Unread")
                    }
                }
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: item.systemImage)
                if item.rating > 0 {
                    Text(String(repeating: "★", count: item.rating)).foregroundStyle(.orange)
                }
                Text(item.modifiedAt, format: .dateTime.day().month())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var preview: some View {
        if item.thumbnailData != nil {
            ThumbnailImage(item: item)
        } else if item.kind == .note, !item.body.isEmpty {
            Text(item.body.prefix(400))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Image(systemName: item.systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if item.label != .none {
                Circle().fill(item.label.color).frame(width: 10, height: 10)
            }
            if item.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
    }
}
