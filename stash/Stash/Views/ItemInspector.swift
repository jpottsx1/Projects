import SwiftUI
import SwiftData
import StashCore

/// The item's category, its links both ways, and when it was made.
struct ItemInspector: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    @State private var isPickingLink = false

    var body: some View {
        Form {
            Section("Category") {
                Picker("Category", selection: $item.category) {
                    Text("None").tag(ItemCategory?.none)
                    ForEach(categoryTree) { category in
                        Text(category.path).tag(Optional(category))
                    }
                }
                .labelsHidden()
            }

            Section {
                ForEach(handLinks) { other in
                    row(for: other)
                        .contextMenu {
                            Button("Remove Link", role: .destructive) { library.unlink(item, other) }
                        }
                }
                ForEach(textLinks, id: \.self) { title in
                    if let target = library.item(titled: title) {
                        row(for: target, note: "in text")
                    } else {
                        Button {
                            library.newNote(titled: title)
                        } label: {
                            Label("Create “\(title)”", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    isPickingLink = true
                } label: {
                    Label("Link to Item…", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Links To")
            } footer: {
                if item.kind == .note {
                    Text("Type [[Title]] in a note to link to an item by name.")
                }
            }

            Section("Linked From") {
                let incoming = backlinks
                if incoming.isEmpty {
                    Text("Nothing links here yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(incoming) { other in
                    row(for: other)
                }
            }

            Section("Info") {
                LabeledContent("Kind", value: item.kind.rawValue.capitalized)
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
        .onChange(of: item.category) { library.didEdit(item) }
        .sheet(isPresented: $isPickingLink) {
            ItemPicker(excluding: item) { other in library.link(item, to: other) }
        }
    }

    private func row(for other: Item, note: String? = nil) -> some View {
        Button {
            library.selection = other
        } label: {
            HStack {
                Label(other.displayTitle, systemImage: other.systemImage)
                Spacer()
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    /// Every category, parents before the categories inside them.
    private var categoryTree: [ItemCategory] {
        categories.filter { $0.parent == nil }.flatMap(\.flattened)
    }

    private var handLinks: [Item] {
        (item.linksTo ?? []).sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    /// `[[Titles]]` written in the note that aren't also hand-made links.
    private var textLinks: [String] {
        guard item.kind == .note else { return [] }
        let linked = Set(handLinks.map { WikiLinks.key($0.title) })
        return WikiLinks.titles(in: item.body).filter { !linked.contains(WikiLinks.key($0)) }
    }

    /// Hand-made links to this item, and notes that name it in a `[[link]]`.
    private var backlinks: [Item] {
        var seen = Set<PersistentIdentifier>()
        return ((item.linkedFrom ?? []) + library.notesLinking(to: item))
            .filter { seen.insert($0.persistentModelID).inserted }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
}

/// Choose another item to link to.
struct ItemPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Item.title) private var items: [Item]
    let excluding: Item
    let onPick: (Item) -> Void
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List(candidates) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    Label(item.displayTitle, systemImage: item.systemImage)
                }
                .buttonStyle(.borderless)
            }
            .searchable(text: $filter, prompt: "Find an item")
            .navigationTitle("Link To")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    private var candidates: [Item] {
        let linked = Set((excluding.linksTo ?? []).map(\.persistentModelID))
        return items.filter { item in
            item != excluding
                && !linked.contains(item.persistentModelID)
                && (filter.isEmpty || item.title.localizedStandardContains(filter))
        }
    }
}
