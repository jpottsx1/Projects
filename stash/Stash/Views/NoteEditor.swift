import SwiftUI
import StashCore

/// Markdown, either as text to edit or as a formatted preview. In the
/// preview `[[links]]` can be followed and task boxes ticked.
struct NoteEditor: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var isPreviewing: Bool

    init(item: Item) {
        self.item = item
        // A new, empty note opens ready to type in; one with words in it opens to read.
        _isPreviewing = State(initialValue: !item.body.isEmpty)
    }

    var body: some View {
        Group {
            if isPreviewing {
                ScrollView {
                    MarkdownView(text: item.body) { line in
                        item.body = MarkdownBlocks.toggleTask(onLine: line, in: item.body)
                    }
                    .padding()
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == Library.linkScheme else { return .systemAction }
                    library.open(wikiURL: url)
                    return .handled
                })
            } else {
                TextEditor(text: $item.body)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
        }
        .onChange(of: item.body) { library.didEdit(item) }
        .toolbar {
            ToolbarItem {
                Picker("Mode", selection: $isPreviewing) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

/// Renders a note's Markdown block by block. Inline formatting -- bold,
/// italics, code, links -- is left to the system's own Markdown support.
struct MarkdownView: View {
    let text: String
    var onToggleTask: (Int) -> Void = { _ in }

    var body: some View {
        let blocks = MarkdownBlocks.parse(WikiLinks.markdownLinks(in: text, scheme: Library.linkScheme))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title : level == 2 ? .title2 : .title3)
                .bold()
                .padding(.top, 4)
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .task(let indent, let done, let text, let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    onToggleTask(line)
                } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundColor(done ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                inline(text)
                    .strikethrough(done)
                    .foregroundColor(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            inline(text)
                .italic()
                .foregroundColor(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}
