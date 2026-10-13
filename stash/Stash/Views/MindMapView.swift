import SwiftUI
import UniformTypeIdentifiers
import StashCore

extension Library {
    /// A new mind map: a note, its centre the title, kept as a nested list.
    @discardableResult
    func newMindMap() -> Item {
        let item = newNote(titled: "Mind Map", text: "- Central Idea")
        item.isMindMap = true
        save()
        return item
    }

    /// The map as a picture, kept as a document beside it and linked from it.
    func savePicture(_ png: Data, of map: Item) {
        guard let document = addDocument(data: png, named: map.displayTitle + ".png", in: map.category) else { return }
        link(map, to: document)
        save()
        selection = document
        Task { await fillThumbnail(of: document) }
    }
}

/// A mind map: the centre on the left, branches to the right. Click a node
/// to choose it; double-click to rename; drag it onto another to move its
/// branch there. Tab adds a branch, Return a node beside, Delete removes.
struct MindMapView: View {
    @Environment(Library.self) private var library
    let item: Item
    @State private var map = MindMap(markdown: "")
    @State private var selected: [Int] = []
    @State private var renaming: [Int]?
    @State private var draft = ""
    @State private var linking = false
    @FocusState private var focused: Bool

    private static let columnWidth: CGFloat = 190
    private static let rowHeight: CGFloat = 46
    private static let margin: CGFloat = 30

    var body: some View {
        let placed = map.layout()
        let rows = (placed.map(\.row).max() ?? 0) + 1
        let columns = CGFloat((placed.map(\.column).max() ?? 0) + 1)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let byPath = Dictionary(uniqueKeysWithValues: placed.map { ($0.path, $0) })
                    for node in placed {
                        guard let parentPath = node.parent, let parent = byPath[parentPath] else { continue }
                        let start = CGPoint(x: Self.x(parent) + Self.columnWidth - 40, y: Self.y(parent))
                        let end = CGPoint(x: Self.x(node), y: Self.y(node))
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: start.x + 40, y: start.y), control2: CGPoint(x: end.x - 40, y: end.y))
                        context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                    }
                }
                ForEach(placed, id: \.path) { node in
                    nodeView(node)
                        .position(x: Self.x(node) + (Self.columnWidth - 40) / 2, y: Self.y(node))
                }
            }
            .frame(width: columns * Self.columnWidth + 2 * Self.margin, height: CGFloat(rows) * Self.rowHeight + 2 * Self.margin)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.tab) { addChild(); return .handled }
        .onKeyPress(.return) { addSibling(); return .handled }
        .onKeyPress(.delete) { deleteSelected(); return .handled }
        .onAppear {
            map = MindMap(markdown: item.body)
            focused = true
        }
        .onChange(of: item.body) {
            // Changed elsewhere (the outline, another device): show it.
            if item.body != map.markdown { map = MindMap(markdown: item.body) }
        }
        .toolbar { toolbar }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renaming { update { $0.rename(renaming, to: draft) } }
            }
        }
        .sheet(isPresented: $linking) {
            ItemPicker(excluding: item) { other in
                let title = map.node(at: selected)?.title ?? ""
                update { $0.rename(selected, to: title.isEmpty ? "[[\(other.displayTitle)]]" : title + " [[\(other.displayTitle)]]") }
            }
        }
    }

    private static func x(_ node: MindMap.Placed) -> CGFloat { margin + CGFloat(node.column) * columnWidth }
    private static func y(_ node: MindMap.Placed) -> CGFloat { margin + CGFloat(node.row) * rowHeight + rowHeight / 2 }

    private func nodeView(_ node: MindMap.Placed) -> some View {
        let isRoot = node.path.isEmpty
        let isSelected = node.path == selected
        return Text(node.title.isEmpty ? " " : node.title)
            .font(isRoot ? .headline : .callout)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: Self.columnWidth - 40)
            .background(isRoot ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Capsule())
            .onTapGesture(count: 2) {
                selected = node.path
                draft = node.title
                renaming = node.path
            }
            .onTapGesture {
                selected = node.path
                focused = true
            }
            .draggable(node.path.map(String.init).joined(separator: "."))
            .dropDestination(for: String.self) { paths, _ in
                guard let text = paths.first else { return false }
                let moving = text.isEmpty ? [] : text.split(separator: ".").compactMap { Int($0) }
                var moved: [Int]?
                update { moved = $0.move(moving, under: node.path) }
                if let moved { selected = moved }
                return moved != nil
            }
            .accessibilityIdentifier("mindNode-\(node.title)")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { addChild() } label: { Label("Add Branch", systemImage: "arrow.turn.down.right") }
                .help("Add a branch to the chosen node (Tab)")
            Button { addSibling() } label: { Label("Add Node Beside", systemImage: "plus.rectangle.on.rectangle") }
                .help("Add a node beside the chosen one (Return)")
            Button {
                draft = map.node(at: selected)?.title ?? ""
                renaming = selected
            } label: { Label("Rename", systemImage: "pencil") }
            Button { linking = true } label: { Label("Link to Item…", systemImage: "link") }
                .help("Put a [[link]] to an item in the chosen node")
            if let title = linkedTitle {
                Button { if let target = library.item(titled: title) { library.show(target) } } label: {
                    Label("Open \(title)", systemImage: "arrow.up.forward.square")
                }
            }
            Button(role: .destructive) { deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected.isEmpty)
            Menu {
                Button("Copy Outline") { copyToClipboard(map.markdown) }
                Button("Save Picture to Stash") { savePicture() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// The item the chosen node links to, if it does.
    private var linkedTitle: String? {
        guard let title = map.node(at: selected)?.title else { return nil }
        return WikiLinks.titles(in: title).first
    }

    private func update(_ change: (inout MindMap) -> Void) {
        change(&map)
        item.body = map.markdown
        library.didEdit(item)
    }

    private func addChild() {
        var added: [Int] = []
        update { added = $0.addChild(to: selected, title: "New Idea") }
        selected = added
        draft = "New Idea"
        renaming = added
    }

    private func addSibling() {
        var added: [Int] = []
        update { added = $0.addSibling(after: selected, title: "New Idea") }
        selected = added
        draft = "New Idea"
        renaming = added
    }

    private func deleteSelected() {
        guard !selected.isEmpty else { return }
        update { $0.delete(selected) }
        selected = Array(selected.dropLast())
    }

    private func savePicture() {
        let renderer = ImageRenderer(content: MindMapPicture(map: map).environment(\.colorScheme, .light))
        renderer.scale = 2
        #if os(macOS)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        #else
        guard let png = renderer.uiImage?.pngData() else { return }
        #endif
        library.savePicture(png, of: item)
    }
}

/// A mind map, or its outline as text to edit directly.
struct MindMapDetail: View {
    let item: Item
    @AppStorage("mindMapShowsOutline") private var showsOutline = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showsOutline) {
                Text("Map").tag(false)
                Text("Outline").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(6)
            Divider()
            if showsOutline {
                NoteEditor(item: item)
            } else {
                MindMapView(item: item)
            }
        }
    }
}

/// The map drawn for a picture: the same layout, on white.
private struct MindMapPicture: View {
    let map: MindMap

    var body: some View {
        let placed = map.layout()
        let width = CGFloat((placed.map(\.column).max() ?? 0) + 1) * 190 + 60
        let height = CGFloat((placed.map(\.row).max() ?? 0) + 1) * 46 + 60
        let byPath = Dictionary(uniqueKeysWithValues: placed.map { ($0.path, $0) })
        func point(_ node: MindMap.Placed) -> CGPoint { CGPoint(x: 30 + CGFloat(node.column) * 190, y: 30 + CGFloat(node.row) * 46 + 23) }
        return ZStack(alignment: .topLeading) {
            Color.white
            Canvas { context, _ in
                for node in placed {
                    guard let parentPath = node.parent, let parent = byPath[parentPath] else { continue }
                    let start = CGPoint(x: point(parent).x + 150, y: point(parent).y), end = point(node)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + 40, y: start.y), control2: CGPoint(x: end.x - 40, y: end.y))
                    context.stroke(path, with: .color(.gray), lineWidth: 1.5)
                }
            }
            ForEach(placed, id: \.path) { node in
                Text(node.title)
                    .font(node.path.isEmpty ? .headline : .callout)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 150)
                    .background(node.path.isEmpty ? Color.orange.opacity(0.25) : Color.gray.opacity(0.15), in: Capsule())
                    .position(x: point(node).x + 75, y: point(node).y)
            }
        }
        .frame(width: width, height: height)
    }
}
