import SwiftUI
import StashCore

/// A section of a note that opens and closes, remembered while it's showing.
struct ToggleSection<Content: View, Label: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen, content: content, label: label)
    }
}

/// A note as Notion's blocks: drag a block by its handle to move it, use its
/// menu to turn it into another kind (text, headings, lists, a to-do, quote,
/// code, a toggle, a divider), add one below, duplicate or delete it.
/// Return at the end of a one-line block starts another of the same kind.
/// The note is written back as Markdown as you go.
struct BlockEditor: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var blocks: [NoteBlock] = []
    @FocusState private var focused: UUID?

    var body: some View {
        List {
            ForEach($blocks) { $block in
                row($block)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .onMove { source, destination in
                blocks.move(fromOffsets: source, toOffset: destination)
                write()
            }
            Button {
                add(NoteBlock(kind: .text), after: blocks.last?.id)
            } label: {
                Label("Add a Block", systemImage: "plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .onAppear { load() }
        .onChange(of: item.body) {
            // Changed elsewhere (another mode, another device): read it again.
            if item.body != NoteBlocks.join(blocks) { load() }
        }
    }

    private func load() {
        blocks = NoteBlocks.split(item.body)
        if blocks.isEmpty { blocks = [NoteBlock(kind: .text)] }
    }

    private func write() {
        let markdown = NoteBlocks.join(blocks)
        guard markdown != item.body else { return }
        item.body = markdown
        library.didEdit(item)
    }

    @ViewBuilder
    private func row(_ block: Binding<NoteBlock>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Menu {
                Menu("Turn Into") {
                    ForEach(NoteBlock.Kind.allCases.filter { $0 != .raw }) { kind in
                        Button(kind.name) {
                            block.wrappedValue = block.wrappedValue.converted(to: kind)
                            write()
                        }
                    }
                }
                Button("Add Block Below") { add(NoteBlock(kind: .text), after: block.wrappedValue.id) }
                Button("Move Up") { shift(block.wrappedValue.id, by: -1) }
                Button("Move Down") { shift(block.wrappedValue.id, by: 1) }
                Button("Duplicate") {
                    var copy = block.wrappedValue
                    copy.id = UUID()
                    add(copy, after: block.wrappedValue.id)
                }
                if block.wrappedValue.kind == .bullet || block.wrappedValue.kind == .numbered || block.wrappedValue.kind == .todo {
                    Button("Indent") { block.wrappedValue.indent += 1; write() }
                    Button("Outdent") { block.wrappedValue.indent = max(block.wrappedValue.indent - 1, 0); write() }
                        .disabled(block.wrappedValue.indent == 0)
                }
                Divider()
                Button("Delete Block", role: .destructive) { remove(block.wrappedValue.id) }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Drag to move; click for more")

            content(block)
                .padding(.leading, CGFloat(block.wrappedValue.indent) * 20)
        }
        .padding(.vertical, block.wrappedValue.kind.isHeading ? 4 : 0)
    }

    @ViewBuilder
    private func content(_ block: Binding<NoteBlock>) -> some View {
        let id = block.wrappedValue.id
        switch block.wrappedValue.kind {
        case .heading1, .heading2, .heading3:
            line(block, font: block.wrappedValue.kind == .heading1 ? .title.bold() : block.wrappedValue.kind == .heading2 ? .title2.bold() : .title3.bold(),
                 prompt: "Heading")
        case .bullet:
            HStack(alignment: .firstTextBaseline) {
                Text("•")
                line(block, prompt: "List")
            }
        case .numbered:
            HStack(alignment: .firstTextBaseline) {
                Text("\(number(of: id)).").monospacedDigit()
                line(block, prompt: "List")
            }
        case .todo:
            HStack(alignment: .firstTextBaseline) {
                Button {
                    block.wrappedValue.done.toggle()
                    write()
                } label: {
                    Image(systemName: block.wrappedValue.done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(block.wrappedValue.done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                line(block, prompt: "To-do")
                    .strikethrough(block.wrappedValue.done)
            }
        case .quote:
            paragraph(block, prompt: "Quote")
                .italic()
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        case .code:
            VStack(alignment: .leading, spacing: 2) {
                TextField("Language", text: Binding(get: { block.wrappedValue.body }, set: { block.wrappedValue.body = $0; write() }))
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                paragraph(block, prompt: "Code")
                    .font(.callout.monospaced())
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .toggle:
            ToggleSection(title: block.wrappedValue.text) {
                TextField("Inside the toggle", text: Binding(get: { block.wrappedValue.body }, set: { block.wrappedValue.body = $0; write() }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)
            } label: {
                line(block, font: .body.bold(), prompt: "Toggle")
            }
        case .divider:
            Divider().frame(maxWidth: .infinity)
        case .raw:
            paragraph(block, prompt: "Markdown")
                .font(.callout.monospaced())
        case .text:
            paragraph(block, prompt: "Type something")
        }
    }

    /// One line: Return starts the next block, of the same kind for lists.
    private func line(_ block: Binding<NoteBlock>, font: Font = .body, prompt: String) -> some View {
        TextField(prompt, text: Binding(get: { block.wrappedValue.text }, set: { block.wrappedValue.text = $0; write() }))
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused, equals: block.wrappedValue.id)
            .onSubmit {
                let current = block.wrappedValue
                let kind: NoteBlock.Kind = [.bullet, .numbered, .todo].contains(current.kind) ? current.kind : .text
                // An empty list item ends the list, as in Notion.
                if current.text.isEmpty, kind != .text {
                    block.wrappedValue = current.converted(to: .text)
                    write()
                    return
                }
                add(NoteBlock(kind: kind, indent: current.indent), after: current.id)
            }
    }

    /// Several lines, as written.
    private func paragraph(_ block: Binding<NoteBlock>, prompt: String) -> some View {
        TextField(prompt, text: Binding(get: { block.wrappedValue.text }, set: { block.wrappedValue.text = $0; write() }), axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused, equals: block.wrappedValue.id)
    }

    private func add(_ block: NoteBlock, after id: UUID?) {
        let index = id.flatMap { id in blocks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? blocks.count
        blocks.insert(block, at: index)
        write()
        focused = block.id
    }

    private func shift(_ id: UUID, by offset: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks.indices.contains(index + offset) else { return }
        blocks = NoteBlocks.moving(blocks, from: index, to: index + offset)
        write()
    }

    private func remove(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        if blocks.isEmpty { blocks = [NoteBlock(kind: .text)] }
        write()
    }

    /// A numbered item's number: its place in its run of numbered items at its level.
    private func number(of id: UUID) -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return 1 }
        let indent = blocks[index].indent
        var count = 1
        var cursor = index - 1
        while cursor >= 0, blocks[cursor].kind == .numbered || blocks[cursor].indent > indent {
            if blocks[cursor].kind == .numbered, blocks[cursor].indent == indent { count += 1 }
            if blocks[cursor].indent < indent { break }
            cursor -= 1
        }
        return count
    }
}

private extension NoteBlock.Kind {
    var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }
}
