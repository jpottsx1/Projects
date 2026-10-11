import SwiftUI
import SwiftData
import StashCore

/// The item's category, its links both ways, and when it was made.
struct ItemInspector: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    @State private var isPickingLink = false
    @State private var seeAlso: [Item] = []

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
                if item.category == nil, let suggested = suggestedCategory {
                    Button {
                        item.category = suggested
                    } label: {
                        Label("File in “\(suggested.path)”", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Where most items like this one are")
                }
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

            Section("Label & Rating") {
                Picker("Label", selection: Binding(get: { item.label }, set: { library.setLabel([item], $0) })) {
                    ForEach(ItemLabel.allCases) { label in
                        if label == .none {
                            Text("None").tag(label)
                        } else {
                            Label {
                                Text(label.name)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(label.color)
                            }
                            .tag(label)
                        }
                    }
                }
                RatingControl(rating: item.rating) { library.setRating([item], $0) }
            }

            if item.isPDF || item.isEPUB || !(item.highlights ?? []).isEmpty {
                Section {
                    let highlights = item.sortedHighlights
                    if highlights.isEmpty {
                        Text("Select text in the \(item.isEPUB ? "book" : "PDF"), then Highlight.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(highlights) { highlight in
                        HighlightRow(highlight: highlight)
                    }
                } header: {
                    Text("Highlights")
                }
            }

            Section {
                if seeAlso.isEmpty {
                    Text("Nothing much like this yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(seeAlso) { other in
                    row(for: other)
                }
            } header: {
                Text("See Also")
            } footer: {
                if !seeAlso.isEmpty {
                    Text("Items that share this one’s most telling words.")
                }
            }

            let copies = library.duplicates(of: item)
            if !copies.isEmpty {
                Section("Also Saved As") {
                    ForEach(copies) { other in
                        row(for: other, note: other.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }

            Section("Info") {
                LabeledContent("Kind", value: item.kind.rawValue.capitalized)
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
        .onChange(of: item.category) { library.didChangeCategory(of: item) }
        // Worked out a moment after typing stops, not on every keystroke.
        .task(id: item.modifiedAt) {
            if !seeAlso.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            seeAlso = library.related(to: item)
        }
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

    /// The category most of the See Also items are in.
    private var suggestedCategory: ItemCategory? {
        let counts = Dictionary(grouping: seeAlso.compactMap(\.category), by: \.persistentModelID)
        return counts.values.max { $0.count < $1.count }?.first
    }

    private var handLinks: [Item] {
        (item.linksTo ?? []).filter { !$0.isTrashed }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
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
        return ((item.linkedFrom ?? []).filter { !$0.isTrashed } + library.notesLinking(to: item))
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
                && !item.isTrashed
                && !linked.contains(item.persistentModelID)
                && (filter.isEmpty || item.title.localizedStandardContains(filter))
        }
    }
}

/// Up to five stars; choosing the current rating again clears it.
struct RatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        LabeledContent("Rating") {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        onChange(stars == rating ? 0 : stars)
                    } label: {
                        Image(systemName: stars <= rating ? "star.fill" : "star")
                            .foregroundStyle(stars <= rating ? .orange : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(stars) stars")
                }
            }
        }
        .accessibilityValue("\(rating) stars")
    }
}

/// A highlight in the side panel: choosing it scrolls the document there.
struct HighlightRow: View {
    @Environment(Library.self) private var library
    let highlight: Highlight

    var body: some View {
        Button {
            library.revealedHighlight = highlight
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(highlight.color.swatch)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlight.text)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                    if !highlight.note.isEmpty {
                        Text(highlight.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Edit Note…") { library.editingHighlight = highlight }
            Menu("Colour") {
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Button(color.name) { library.update(highlight, color: color) }
                }
            }
            Divider()
            Button("Delete Highlight", role: .destructive) { library.delete(highlight) }
        }
    }
}

/// Writes the note on a highlight, changes its colour, or deletes it.
struct HighlightNoteEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let highlight: Highlight
    @State private var note: String

    init(highlight: Highlight) {
        self.highlight = highlight
        _note = State(initialValue: highlight.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(highlight.text)
                        .italic()
                        .textSelection(.enabled)
                    Picker("Colour", selection: Binding(get: { highlight.color },
                                                       set: { library.update(highlight, color: $0) })) {
                        ForEach(HighlightColor.allCases, id: \.self) { color in
                            Text(color.name).tag(color)
                        }
                    }
                }
                Section("Note") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                }
                Section {
                    Button("Delete Highlight", role: .destructive) {
                        library.delete(highlight)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Highlight")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        library.update(highlight, note: note)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 380)
    }
}
