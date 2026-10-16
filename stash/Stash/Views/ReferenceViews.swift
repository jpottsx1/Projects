import SwiftUI
import StashCore

/// The side panel's reference: who, where, when, to cite it.
struct ReferenceSection: View {
    @Environment(Library.self) private var library
    let item: Item
    @State private var draft = Reference()
    @AppStorage("citationStyle") private var style = Reference.Style.apa.rawValue

    var body: some View {
        Section {
            DisclosureGroup("Reference") {
                field("Title", \.title)
                TextField("Authors", text: Binding(get: { draft.authors.joined(separator: "; ") }, set: { value in
                    draft.authors = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    commit()
                }), prompt: Text("Authors, separated by ;"))
                field("Site or Publication", \.siteName)
                field("Publisher", \.publisher)
                field("Published", \.published, prompt: "2024-05-06")
                field("Address", \.url)
                field("DOI", \.doi)
                if !draft.journal.isEmpty || !draft.volume.isEmpty {
                    field("Journal", \.journal)
                    field("Volume", \.volume)
                    field("Issue", \.issue)
                    field("Pages", \.pages)
                }
                LabeledContent("Saved", value: draft.accessed)
                HStack {
                    Menu("Copy Citation") {
                        ForEach(Reference.Style.allCases) { style in
                            Button(style.name) { copyToClipboard(library.citableReference(of: item).citation(style)) }
                        }
                        Button("BibTeX") { copyToClipboard(library.citableReference(of: item).bibTeX(key: Self.key(for: item, draft))) }
                    }
                    .fixedSize()
                    if item.kind == .link {
                        Button("Read from Page") { Task { await library.refreshPage(of: item); draft = library.reference(of: item) } }
                    }
                }
                .buttonStyle(.borderless)
                Text(library.citableReference(of: item).citation(Reference.Style(rawValue: style) ?? .apa))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { draft = library.reference(of: item) }
        .onChange(of: item.referenceJSON) { draft = library.reference(of: item) }
    }

    private func field(_ label: String, _ path: WritableKeyPath<Reference, String>, prompt: String? = nil) -> some View {
        TextField(label, text: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0; commit() }),
                  prompt: prompt.map(Text.init))
    }

    private func commit() {
        guard draft.json != item.referenceJSON else { return }
        library.setReference(draft, of: item)
    }

    /// smith2024, as reference managers name entries.
    static func key(for item: Item, _ reference: Reference) -> String {
        let author = reference.authors.first.map { $0.split(separator: " ").last.map(String.init) ?? $0 } ?? item.displayTitle.split(separator: " ").first.map(String.init) ?? "item"
        let year = reference.published.prefix(4)
        return (author + year).lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Gathering highlights from several items into one Markdown document, with references.
struct HighlightsDocumentSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let items: [Item]
    @State private var title = ""
    @State private var useLinks = false
    @AppStorage("citationStyle") private var style = Reference.Style.apa.rawValue

    /// A single note: the items it links to are the sources.
    private var note: Item? { items.count == 1 && items[0].kind == .note ? items[0] : nil }

    private var sources: [Item] {
        if useLinks, let note { return library.linkedItems(from: note) }
        return items
    }

    var body: some View {
        let withHighlights = sources.filter { !($0.highlights ?? []).isEmpty && !$0.isLocked }
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    if note != nil {
                        Picker("Gather From", selection: $useLinks) {
                            Text("Items Linked from “\(note?.displayTitle ?? "")”").tag(true)
                            Text("This Note").tag(false)
                        }
                    }
                    Picker("References", selection: $style) {
                        ForEach(Reference.Style.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                } footer: {
                    Text("A note with each source's highlights (and your notes on them) under its title, footnoted to its reference — author, title, site, date and address, from what was saved with it — and the references at the end, each with a link back. It's Markdown, so it exports and pastes anywhere.")
                }
                Section("\(withHighlights.count) of \(sources.count) have highlights") {
                    ForEach(withHighlights.prefix(30)) { item in
                        LabeledContent(item.displayTitle, value: "\((item.highlights ?? []).count)")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Highlights Document")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make") {
                        if let made = library.makeHighlightsDocument(from: sources, titled: title.isEmpty ? "Highlights" : title,
                                                                     style: Reference.Style(rawValue: style) ?? .apa) {
                            library.show(made)
                        }
                        dismiss()
                    }
                    .disabled(withHighlights.isEmpty)
                }
            }
        }
        .sheetSize(minWidth: 460, minHeight: 440)
        .onAppear {
            useLinks = note.map { (library.linkedItems(from: $0)).contains { !($0.highlights ?? []).isEmpty } } ?? false
            title = note.map { "Highlights: " + $0.displayTitle } ?? "Highlights"
        }
    }
}
