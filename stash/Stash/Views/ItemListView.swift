import SwiftUI
import SwiftData
import StashCore

struct ItemListView: View {
    @Environment(Library.self) private var library
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]

    var body: some View {
        @Bindable var library = library
        let items = library.visibleItems(from: allItems)
        List(selection: $library.selection) {
            ForEach(items) { item in
                ItemRow(item: item)
                    .tag(item)
                    .contextMenu {
                        Button("Delete", role: .destructive) { library.delete([item]) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { library.delete([item]) }
                    }
            }
        }
        .overlay {
            if items.isEmpty { emptyState }
        }
        .navigationTitle(library.sidebarTitle)
        .searchable(text: $library.searchText, prompt: "Search, or #tag")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AddMenu() }
        }
        // Files from Finder or Files become documents; web addresses become links.
        .dropDestination(for: URL.self) { urls, _ in
            library.add(urls)
            return !urls.isEmpty
        }
        #if os(macOS)
        .onDeleteCommand {
            if let item = library.selection { library.delete([item]) }
        }
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText)
        } else {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: "tray")
            } description: {
                Text("Add a note, save a link, or drop documents here.")
            }
        }
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
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
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
