import SwiftUI
import SwiftData
import StashCore

struct ItemDetailView: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item

    /// Open beside the item on a Mac or iPad. On an iPhone it's a sheet, so
    /// it starts closed.
    @AppStorage("showInspector") private var showInspector = ItemDetailView.inspectorOpenByDefault
    #if os(iOS)
    private static let inspectorOpenByDefault = false
    #else
    private static let inspectorOpenByDefault = true
    #endif

    @FocusState private var titleFocused: Bool
    @State private var titleBeforeEditing = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.isTrashed {
                TrashBanner(item: item)
            } else if item.inInbox {
                InboxBanner(item: item)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $item.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                TagEditor(item: item)
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            Divider()

            switch item.kind {
            case .note: NoteEditor(item: item)
            case .link: LinkDetail(item: item)
            case .document: DocumentDetail(item: item)
            }
        }
        .onChange(of: item.title) { library.didEdit(item) }
        // `[[links]]` follow a rename once the title is finished, not on
        // every keystroke while it's half typed.
        .onChange(of: titleFocused) { _, focused in
            if focused {
                titleBeforeEditing = item.title
            } else {
                library.rename(item, from: titleBeforeEditing)
            }
        }
        .onDisappear {
            if titleFocused { library.rename(item, from: titleBeforeEditing) }
        }
        .inspector(isPresented: $showInspector) {
            ItemInspector(item: item)
                .inspectorColumnWidth(min: 220, ideal: 270, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.setFavorite([item], !item.isFavorite)
                } label: {
                    Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: item.isFavorite ? "star.fill" : "star")
                }
                .disabled(item.isTrashed)
                .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Category & Links", systemImage: "sidebar.right")
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Says an item is waiting in the Inbox, with ways to file it.
struct InboxBanner: View {
    @Environment(Library.self) private var library
    let item: Item
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]

    var body: some View {
        HStack {
            Label("In the Inbox", systemImage: "tray.and.arrow.down")
                .font(.callout.weight(.medium))
            Spacer()
            Menu("File In") {
                ForEach(categories.filter { $0.parent == nil }.flatMap(\.flattened)) { category in
                    Button(category.path) { library.file([item], in: category) }
                }
            }
            .fixedSize()
            .disabled(categories.isEmpty)
            Button("Done") { library.markFiled([item]) }
                .help("Take it out of the Inbox without a category")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.12))
    }
}

/// Says an item is in the Trash, with a way to put it back.
struct TrashBanner: View {
    @Environment(Library.self) private var library
    let item: Item

    var body: some View {
        HStack {
            Label("In the Trash", systemImage: "trash")
                .font(.callout.weight(.medium))
            if let days = daysLeft {
                Text(days == 1 ? "Deleted tomorrow" : "Deleted in \(days) days")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Put Back") { library.restore([item]) }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.15))
    }

    private var daysLeft: Int? {
        guard let trashedAt = item.trashedAt,
              let end = Calendar.current.date(byAdding: .day, value: Library.trashDays, to: trashedAt) else { return nil }
        return max(1, Calendar.current.dateComponents([.day], from: .now, to: end).day ?? 0)
    }
}

/// Tags as chips, with a field to add more (commas add several at once)
/// and a menu of tags already in use.
struct TagEditor: View {
    @Environment(Library.self) private var library
    let item: Item
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(item.sortedTags) { tag in
                HStack(spacing: 3) {
                    Text("#" + tag.name)
                    Button {
                        library.removeTag(tag, from: item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(tag.name)")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            TextField("Add tags", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 110)
                .autocorrectionDisabled()
                .onSubmit {
                    library.addTags(from: draft, to: item)
                    draft = ""
                }

            let unused = allTags.filter { !item.hasTag(key: $0.key) }
            if !unused.isEmpty {
                Menu {
                    ForEach(unused) { tag in
                        Button(tag.name) { library.addTags(from: tag.name, to: item) }
                    }
                } label: {
                    Image(systemName: "number")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Add an existing tag")
            }
        }
    }
}

/// Lays its children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
