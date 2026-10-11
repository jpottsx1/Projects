import SwiftUI
import SwiftData
import StashCore

/// Markdown, either as text to edit or as a formatted preview. In the
/// preview `[[links]]` can be followed and task boxes ticked; while editing,
/// typing `[[` suggests items to link to.
struct NoteEditor: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var isPreviewing: Bool

    /// Most recently edited first, which is the order suggestions keep.
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var completion: WikiLinkCompletion.Context?
    @State private var highlighted = 0
    @State private var moveCursorTo: String.Index?

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
                NoteTextEditor(text: $item.body, moveCursorTo: $moveCursorTo) { cursor in
                    updateCompletion(at: cursor)
                }
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.return) { acceptHighlighted() }
                .onKeyPress(.tab) { acceptHighlighted() }
                .onKeyPress(.escape) {
                    guard completion != nil else { return .ignored }
                    completion = nil
                    return .handled
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    let choices = self.choices
                    if !choices.isEmpty {
                        LinkSuggestions(choices: choices, highlighted: min(highlighted, choices.count - 1)) { choice in
                            accept(choice)
                        }
                    }
                }
            }
        }
        .onChange(of: item.body) { library.didEdit(item) }
        .onChange(of: isPreviewing) { completion = nil }
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

    // MARK: - Suggesting links

    /// What to offer for the link being typed: items whose titles match,
    /// then -- if none is called exactly that -- a new note by that name.
    private var choices: [LinkChoice] {
        guard let completion else { return [] }
        let candidates = allItems.filter { $0 != item && !$0.title.isEmpty }
        let byKey = Dictionary(candidates.map { (WikiLinks.key($0.title), $0) }, uniquingKeysWith: { first, _ in first })
        var result = WikiLinkCompletion.rank(candidates.map(\.title), for: completion.query, limit: 6)
            .compactMap { byKey[WikiLinks.key($0)].map(LinkChoice.existing) }
        let typed = completion.query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, byKey[WikiLinks.key(typed)] == nil {
            result.append(.new(typed))
        }
        return result
    }

    private func updateCompletion(at cursor: String.Index) {
        let found = WikiLinkCompletion.context(in: item.body, cursor: cursor)
        if found?.query != completion?.query { highlighted = 0 }
        completion = found
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        let count = choices.count
        guard count > 0 else { return .ignored }
        highlighted = (min(highlighted, count - 1) + step + count) % count
        return .handled
    }

    private func acceptHighlighted() -> KeyPress.Result {
        let choices = self.choices
        guard !choices.isEmpty else { return .ignored }
        accept(choices[min(highlighted, choices.count - 1)])
        return .handled
    }

    /// Writes the link in. A new note isn't made here: following the link
    /// in the preview makes it, as for any link to a missing item.
    private func accept(_ choice: LinkChoice) {
        guard let completion else { return }
        let done = WikiLinkCompletion.complete(item.body, context: completion, with: choice.title)
        item.body = done.text
        moveCursorTo = done.cursor
        self.completion = nil
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
