import SwiftUI
import SwiftData
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

            FieldsSection(item: item)
            ListsAndReadingSection(item: item)
            if !item.isLocked { AssistantSection(item: item) }

            Section("Reminder") {
                if let date = item.remindAt {
                    DatePicker("Remind Me", selection: Binding(get: { date }, set: { library.setReminder([item], at: $0) }),
                               displayedComponents: [.date, .hourAndMinute])
                    Button(item.isDue ? "Done" : "Clear Reminder") { library.setReminder([item], at: nil) }
                        .buttonStyle(.borderless)
                } else {
                    ReminderMenu(items: [item])
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

            if item.isPDF || item.isEPUB || item.articleData != nil || !(item.highlights ?? []).isEmpty {
                Section {
                    let highlights = item.sortedHighlights
                    if highlights.isEmpty {
                        Text("Select text in the \(item.isEPUB ? "book" : item.kind == .link ? "article" : "PDF"), then Highlight.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(highlights) { highlight in
                        HighlightRow(highlight: highlight)
                    }
                    if !highlights.isEmpty {
                        HStack {
                            Button("Make Note") { library.makeHighlightsNote(for: item) }
                                .help("A note of these highlights and their notes, linked to this item")
                            Spacer()
                            Button("Copy") { copyToClipboard(library.highlightsMarkdown(for: item)) }
                                .help("Copy the highlights as Markdown")
                        }
                        .buttonStyle(.borderless)
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
                Section {
                    ForEach(copies) { other in
                        row(for: other, note: other.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Merge Copies Into This One") { library.mergeDuplicates(into: item) }
                        .buttonStyle(.borderless)
                } header: {
                    Text("Also Saved As")
                } footer: {
                    Text("Merging keeps this one, with the others’ tags, notes, highlights and links, and puts the others in the Trash.")
                }
            }

            let suggested = suggestedTags
            if !suggested.isEmpty {
                Section {
                    FlowLayout(spacing: 6) {
                        ForEach(suggested, id: \.self) { name in
                            Button("+ #" + name) { library.addTags(from: name, to: item) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Suggested Tags")
                } footer: {
                    Text("Tags on the items most like this one.")
                }
            }

            let mentions = library.unlinkedMentions(of: item)
            if !mentions.isEmpty {
                Section {
                    ForEach(mentions) { note in
                        HStack {
                            row(for: note)
                            Spacer()
                            Button("Link") { library.linkMentions(in: note, to: item) }
                                .buttonStyle(.borderless)
                                .help("Make its mentions of “\(item.displayTitle)” into [[links]]")
                        }
                    }
                } header: {
                    Text("Unlinked Mentions")
                } footer: {
                    Text("Notes that name this item without linking to it.")
                }
            }

            if item.kind == .note {
                Section("History") {
                    let count = item.versions?.count ?? 0
                    Button(count == 0 ? "No Earlier Versions Yet" : count == 1 ? "1 Earlier Version…" : "\(count) Earlier Versions…") {
                        library.viewingHistoryOf = item
                    }
                    .buttonStyle(.borderless)
                    .disabled(count == 0)
                }
            }

            Section("Info") {
                LabeledContent("Kind", value: item.isTemplate ? "Template" : item.kind.rawValue.capitalized)
                if let feed = item.feed {
                    LabeledContent("Feed", value: feed.title)
                }
                if let folder = item.indexedFolder {
                    LabeledContent("Indexed In") {
                        Text((folder.name as NSString).appendingPathComponent(item.indexedPath ?? ""))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    #if os(macOS)
                    Button("Show in Finder") { library.showInFinder(item) }
                        .buttonStyle(.borderless)
                        .disabled(library.localFile(for: item) == nil)
                    #endif
                }
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

    /// Tags on two or more of the See Also items that this one hasn't got.
    private var suggestedTags: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for other in seeAlso {
            for tag in other.tags ?? [] where !item.hasTag(key: tag.key) {
                counts[tag.key, default: (tag.name, 0)].count += 1
            }
        }
        return counts.values.filter { $0.count >= 2 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(6).map(\.name)
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
        .sheetSize(minWidth: 360, minHeight: 420)
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
                    .frame(maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Plain, so the passage reads as text rather than as a link.
        .buttonStyle(.plain)
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
        .sheetSize(minWidth: 380, minHeight: 380)
    }
}

/// Puts text on the clipboard.
@MainActor
func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
