import SwiftUI
import SwiftData
import StashCore

/// The notebooks in the sidebar.
struct NotebooksSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \Notebook.name) private var notebooks: [Notebook]
    @State private var renaming: Notebook?
    @State private var isNaming = false
    @State private var draft = ""

    var body: some View {
        Section("Notebooks") {
            ForEach(notebooks) { notebook in
                Label(notebook.name, systemImage: "book.pages")
                    .badge((notebook.cards ?? []).count)
                    .tag(SidebarSelection.notebook(notebook))
                    .contextMenu {
                        Button("Rename…") {
                            draft = notebook.name
                            renaming = notebook
                        }
                        Divider()
                        Button("Delete Notebook", role: .destructive) { library.delete(notebook) }
                    }
            }
            Button {
                draft = ""
                isNaming = true
            } label: {
                Label("New Notebook", systemImage: "plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("A notebook to study documents in, as MarginNote: what you highlight becomes cards in its map")
            .alert("New Notebook", isPresented: $isNaming) {
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Make") { library.newNotebook(named: draft) }
            }
            .alert("Rename Notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let renaming { library.rename(renaming, to: draft) } }
            }
        }
    }
}

/// *Add to Notebook* in item menus.
struct NotebookMenu: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            Menu("Add to Notebook") {
                ForEach(library.notebooks()) { notebook in
                    Button(notebook.name) { library.add(items, to: notebook) }
                }
                Divider()
                Button("New Notebook with \(items.count == 1 ? "This" : "These")") { library.newNotebook(with: items) }
            }
            if let notebook = library.studiedNotebook, items.contains(where: { ($0.notebooks ?? []).contains(notebook) }) {
                Button("Remove from “\(notebook.name)”") { library.remove(items, from: notebook) }
            }
        }
    }
}

/// MarginNote's study view: the document on one side, the notebook's map
/// of cards on the other. Highlighting in the document adds a card under
/// the one chosen; a card's double-click goes back to its passage.
struct StudyView: View {
    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    let notebook: Notebook
    let item: Item?
    @State private var showsMapOnPhone = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(spacing: 0) {
                    Picker("Show", selection: $showsMapOnPhone) {
                        Text("Document").tag(false)
                        Text("Map").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(6)
                    if showsMapOnPhone { StudyPanel(notebook: notebook, item: item) } else { document }
                }
            } else {
                #if os(macOS)
                HSplitView {
                    document.frame(minWidth: 320)
                    StudyPanel(notebook: notebook, item: item).frame(minWidth: 320)
                }
                #else
                HStack(spacing: 0) {
                    document
                    Divider()
                    StudyPanel(notebook: notebook, item: item)
                }
                #endif
            }
        }
        .sheet(item: Binding(get: { library.editingCard }, set: { library.editingCard = $0 })) { card in
            CardEditor(card: card)
        }
    }

    @ViewBuilder
    private var document: some View {
        if let item {
            ItemDetailView(item: item)
                .id(item.persistentModelID)
        } else {
            ContentUnavailableView {
                Label("Choose a Document", systemImage: "book.pages")
            } description: {
                Text("Add documents to “\(notebook.name)” (Add to Notebook in an item's menu) and choose one to read. What you highlight becomes a card in the map, under the card chosen.")
            }
        }
    }
}

/// The notebook's cards: a map, an outline, or title links for the document.
struct StudyPanel: View {
    @Environment(Library.self) private var library
    let notebook: Notebook
    let item: Item?

    enum Mode: String, CaseIterable, Identifiable {
        case map = "Map", outline = "Outline", links = "Title Links"
        var id: String { rawValue }
    }

    @AppStorage("studyPanelMode") private var mode = Mode.map.rawValue
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button {
                    let card = library.addCard(title: "New Card", under: library.card(library.chosenCardID, in: notebook), in: notebook)
                    library.chosenCardID = card.uuid
                    library.editingCard = card
                } label: { Label("Add Card", systemImage: "plus.rectangle") }
                    .help("A card of your own, under the one chosen")
                Menu {
                    Button("Collect Highlights") {
                        let count = library.collectHighlights(in: notebook)
                        message = count == 0 ? "Every highlight already has a card." : "Added \(count) cards."
                    }
                    if let item, item.isPDF {
                        Button("From the Table of Contents") {
                            let count = library.mapContents(of: item, in: notebook)
                            message = count == 0 ? "“\(item.displayTitle)” has no table of contents." : "Added \(count) headings."
                        }
                    }
                    Button("Group by Concepts") {
                        let count = library.mapConcepts(in: notebook)
                        message = count == 0 ? "Not enough highlights share words to group." : "Grouped into \(count) concepts."
                    }
                } label: { Label("Auto Map", systemImage: "wand.and.stars") }
                    .help("Cards from highlights already made, from a PDF's table of contents, or grouped by the words they share")
                Menu {
                    Button("Copy Outline") { copyToClipboard(library.outline(of: notebook)) }
                    Button("Save as Mind Map Note") { library.selection = library.saveAsMindMap(notebook) }
                    Button("Highlights Document…") { library.highlightsDocumentItems = notebook.orderedItems }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            switch Mode(rawValue: mode) ?? .map {
            case .map: CardMapView(notebook: notebook)
            case .outline: CardOutlineView(notebook: notebook)
            case .links: TitleLinksView(item: item)
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }
}

/// What can be done to a card, in its menus.
struct CardMenu: View {
    @Environment(Library.self) private var library
    let card: StudyCard

    var body: some View {
        Button("Edit…") { library.editingCard = card }
        if card.sourceItemID != nil {
            Button("Go to Source") { library.goToSource(of: card) }
        }
        Button("Add Card Under") {
            if let notebook = card.notebook {
                let made = library.addCard(title: "New Card", under: card, in: notebook)
                library.chosenCardID = made.uuid
                library.editingCard = made
            }
        }
        Menu("Color") {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button(color.name) { library.update(card, color: color.rawValue) }
            }
        }
        Divider()
        Button("Move Up") { library.shift(card, by: -1) }
        Button("Move Down") { library.shift(card, by: 1) }
        Button("Indent") { library.indent(card) }
        Button("Outdent") { library.outdent(card) }.disabled(card.parent == nil)
        Button("Merge into Card Above") { library.mergeIntoParent(card) }.disabled(card.parent == nil)
        Divider()
        Button("Delete Card", role: .destructive) { library.delete(card) }
    }
}

/// MarginNote's map: the notebook in the middle-left, cards branching
/// right. Click to choose a card (new excerpts go under it); double-click
/// to go to its passage; drag one onto another to put it there. Dashed
/// lines are card links.
struct CardMapView: View {
    @Environment(Library.self) private var library
    let notebook: Notebook

    private static let columnWidth: CGFloat = 240
    private static let rowHeight: CGFloat = 78
    private static let margin: CGFloat = 24
    private static let cardWidth: CGFloat = 200

    var body: some View {
        let _ = library.revision
        let cards = notebook.cards ?? []
        let byID = Dictionary(cards.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let (map, paths) = StudyMap.mindMap(Library.plan(cards), title: notebook.name)
        let placed = map.layout()
        let byPath = Dictionary(placed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let pathOf = Dictionary(paths.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = (placed.map(\.row).max() ?? 0) + 1
        let columns = CGFloat((placed.map(\.column).max() ?? 0) + 1)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for node in placed {
                        guard let parentPath = node.parent, let parent = byPath[parentPath] else { continue }
                        let start = CGPoint(x: Self.x(parent) + Self.cardWidth, y: Self.y(parent))
                        let end = CGPoint(x: Self.x(node), y: Self.y(node))
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: start.x + 30, y: start.y), control2: CGPoint(x: end.x - 30, y: end.y))
                        context.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
                    }
                    // Card links, dashed, each drawn once.
                    for card in cards {
                        for other in card.links where card.uuid.uuidString < other.uuidString {
                            guard let a = pathOf[card.uuid].flatMap({ byPath[$0] }),
                                  let b = pathOf[other].flatMap({ byPath[$0] }) else { continue }
                            var path = Path()
                            path.move(to: CGPoint(x: Self.x(a) + Self.cardWidth / 2, y: Self.y(a)))
                            path.addLine(to: CGPoint(x: Self.x(b) + Self.cardWidth / 2, y: Self.y(b)))
                            context.stroke(path, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        }
                    }
                }
                ForEach(placed, id: \.path) { node in
                    nodeView(node, card: paths[node.path].flatMap { byID[$0] })
                        .position(x: Self.x(node) + Self.cardWidth / 2, y: Self.y(node))
                }
            }
            .frame(width: columns * Self.columnWidth + 2 * Self.margin, height: CGFloat(rows) * Self.rowHeight + 2 * Self.margin)
        }
        .overlay {
            if cards.isEmpty {
                ContentUnavailableView("No Cards Yet", systemImage: "rectangle.on.rectangle",
                                       description: Text("Highlight a passage in the document and it becomes a card here. Or use Auto Map to start from highlights already made, or a PDF's table of contents."))
            }
        }
    }

    private static func x(_ node: MindMap.Placed) -> CGFloat { margin + CGFloat(node.column) * columnWidth }
    private static func y(_ node: MindMap.Placed) -> CGFloat { margin + CGFloat(node.row) * rowHeight + rowHeight / 2 }

    @ViewBuilder
    private func nodeView(_ node: MindMap.Placed, card: StudyCard?) -> some View {
        if let card {
            CardView(card: card, isChosen: library.chosenCardID == card.uuid)
                .frame(width: Self.cardWidth)
                .onTapGesture(count: 2) { library.goToSource(of: card) }
                .onTapGesture { library.chosenCardID = card.uuid }
                .contextMenu { CardMenu(card: card) }
                .draggable(card.uuid.uuidString)
                .dropDestination(for: String.self) { ids, _ in drop(ids, onto: card) }
        } else {
            // The notebook itself: choose it to put new excerpts at the top.
            Text(notebook.name)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: Self.cardWidth)
                .background(Color.accentColor.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(library.chosenCardID == nil ? Color.accentColor : .clear, lineWidth: 2))
                .onTapGesture { library.chosenCardID = nil }
                .dropDestination(for: String.self) { ids, _ in drop(ids, onto: nil) }
        }
    }

    private func drop(_ ids: [String], onto target: StudyCard?) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)), let moving = library.card(id, in: notebook) else { return false }
        return library.move(moving, under: target)
    }
}

/// One card: its title, excerpt and comment, in its colour.
struct CardView: View {
    let card: StudyCard
    let isChosen: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill((HighlightColor(rawValue: card.colorRaw) ?? .yellow).swatch)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                if !card.title.isEmpty {
                    Text(card.title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                if !card.excerpt.isEmpty {
                    Text(card.excerpt).font(.caption).lineLimit(card.title.isEmpty ? 3 : 2)
                }
                if !card.comment.isEmpty {
                    Label(card.comment, systemImage: "text.bubble").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(6)
            Spacer(minLength: 0)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isChosen ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                lineWidth: isChosen ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityIdentifier("studyCard-\(card.title.isEmpty ? card.excerpt.prefix(20) : card.title.prefix(20))")
    }
}

/// The same cards as an outline, indented as they nest.
struct CardOutlineView: View {
    @Environment(Library.self) private var library
    let notebook: Notebook

    var body: some View {
        let _ = library.revision
        let cards = notebook.cards ?? []
        let byID = Dictionary(cards.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        List {
            ForEach(StudyMap.flattened(Library.plan(cards)), id: \.card.id) { entry in
                if let card = byID[entry.card.id] {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill((HighlightColor(rawValue: card.colorRaw) ?? .yellow).swatch)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Title", text: Binding(get: { card.title }, set: { library.update(card, title: $0) }),
                                      prompt: Text(card.excerpt.isEmpty ? "Title" : "Add a title"))
                                .textFieldStyle(.plain)
                                .font(.callout.weight(.semibold))
                            if !card.excerpt.isEmpty {
                                Text("“\(card.excerpt)”").font(.callout).foregroundStyle(.secondary).lineLimit(4)
                            }
                            if !card.comment.isEmpty {
                                Text(card.comment).font(.caption)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(entry.depth) * 20)
                    .listRowBackground(library.chosenCardID == card.uuid ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { library.chosenCardID = card.uuid }
                    .contextMenu { CardMenu(card: card) }
                }
            }
        }
        .listStyle(.plain)
    }
}

/// MarginNote's title links: titles of cards made before (in any notebook)
/// that turn up in this document, with the pages, and what was noted.
struct TitleLinksView: View {
    @Environment(Library.self) private var library
    let item: Item?
    @State private var matches: [TitleLinks.Match]?

    var body: some View {
        Group {
            if item == nil {
                ContentUnavailableView("Choose a Document", systemImage: "link",
                                       description: Text("Title links show where cards' titles turn up in the document you're reading."))
            } else if let matches, !matches.isEmpty {
                List(matches, id: \.title) { match in
                    Section(match.title) {
                        HStack {
                            Text(match.pages.count == 1 ? "On page" : "On pages").foregroundStyle(.secondary)
                            ForEach(match.pages.prefix(12), id: \.self) { page in
                                Button("\(page + 1)") {
                                    if let item { library.revealedPage = PageRequest(itemID: item.uuid, page: page) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        ForEach(library.cards(titled: match.title).prefix(4)) { card in
                            VStack(alignment: .leading, spacing: 2) {
                                if !card.excerpt.isEmpty { Text("“\(card.excerpt)”").font(.caption).lineLimit(3) }
                                if !card.comment.isEmpty { Text(card.comment).font(.caption).foregroundStyle(.secondary) }
                                Text("In “\(card.notebook?.name ?? "")”").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { library.goToSource(of: card) }
                        }
                    }
                }
            } else if matches != nil {
                ContentUnavailableView("No Title Links", systemImage: "link",
                                       description: Text("None of your cards' titles turn up in this document. Give cards titles (concepts, names, terms) and they'll be found in what you read next."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(item?.uuid.uuidString ?? "")-\(library.revision)") {
            guard let item else { return }
            matches = await library.titleLinks(in: item)
        }
    }
}

/// A card's title, comment, colour and links.
struct CardEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let card: StudyCard
    @State private var title = ""
    @State private var comment = ""
    @State private var color = "yellow"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("A concept, name or term"))
                    Picker("Color", selection: $color) {
                        ForEach(HighlightColor.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
                    }
                } footer: {
                    Text("Titled cards are found again wherever their title turns up in other documents (Title Links).")
                }
                if !card.excerpt.isEmpty {
                    Section("Excerpt") { Text(card.excerpt).textSelection(.enabled) }
                }
                Section("Comment") {
                    TextEditor(text: $comment).frame(minHeight: 80)
                }
                Section("Linked Cards") {
                    let others = (card.notebook?.cards ?? []).filter { $0 != card }
                    ForEach(others.filter { card.links.contains($0.uuid) }) { other in
                        HStack {
                            Text(other.title.isEmpty ? ConceptMap.short(other.excerpt, 60) : other.title).lineLimit(1)
                            Spacer()
                            Button("Unlink") { library.unlink(card, other) }.buttonStyle(.borderless)
                        }
                    }
                    Menu("Link to Card…") {
                        ForEach(others.filter { !card.links.contains($0.uuid) }) { other in
                            Button(other.title.isEmpty ? ConceptMap.short(other.excerpt, 60) : other.title) { library.link(card, to: other) }
                        }
                    }
                    .disabled(others.isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.update(card, title: title, comment: comment, color: color)
                        dismiss()
                    }
                }
            }
        }
        .sheetSize(minWidth: 420, minHeight: 480)
        .onAppear {
            title = card.title
            comment = card.comment
            color = card.colorRaw
        }
    }
}
