import SwiftUI
import SwiftData
import StashCore

/// Markdown as text to edit, as a formatted preview, or both side by side
/// where there's room. In the preview `[[links]]` can be followed and task
/// boxes ticked; while editing, typing `[[` suggests items to link to, and
/// the formatting buttons mark up the selected text.
struct NoteEditor: View {
    enum Mode: String {
        case edit, split, preview
    }

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var item: Item
    @State private var mode: Mode

    /// Most recently edited first, which is the order suggestions keep.
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var completion: WikiLinkCompletion.Context?
    @State private var highlighted = 0
    @State private var select: Range<String.Index>?
    /// The selection as character offsets, for the formatting buttons.
    @State private var selection: Range<Int>?

    init(item: Item) {
        self.item = item
        // A new, empty note opens ready to type in; one with words in it opens to read.
        _mode = State(initialValue: item.body.isEmpty ? .edit : .preview)
    }

    var body: some View {
        Group {
            switch mode {
            case .preview:
                preview
            case .edit:
                editor
            case .split:
                HStack(spacing: 0) {
                    editor
                    Divider()
                    preview
                }
            }
        }
        .onChange(of: item.body) { library.didEdit(item) }
        .onChange(of: mode) { completion = nil }
        .onAppear { library.beginEditing(item) }
        .onDisappear { library.endEditing(item) }
        .toolbar {
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    Text("Edit").tag(Mode.edit)
                    if sizeClass != .compact {
                        Text("Split").tag(Mode.split)
                    }
                    Text("Preview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            #if os(iOS)
            ToolbarItem(placement: .keyboard) {
                // Nine buttons are wider than a phone: they scroll.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        FormatButtons(apply: format)
                    }
                    .padding(.horizontal, 4)
                }
            }
            #endif
        }
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(text: item.body) { line in
                item.body = MarkdownBlocks.toggleTask(onLine: line, in: item.body)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Library.linkScheme else { return .systemAction }
            library.open(wikiURL: url)
            return .handled
        })
    }

    private var editor: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 2) {
                FormatButtons(apply: format)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            #endif
            NoteTextEditor(text: $item.body, select: $select, onCursorMoved: { cursor in
                updateCompletion(at: cursor)
            }, onSelectionChanged: { range in
                selection = range
            })
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

    /// Marks up the selection; with nothing known to be selected, the end of the note.
    private func format(_ style: MarkdownFormatting.Style) {
        let text = item.body
        let end = text.count
        let range = selection.map { min($0.lowerBound, end)..<min($0.upperBound, end) } ?? (end..<end)
        let result = MarkdownFormatting.apply(style, to: text, selection: range)
        item.body = result.text
        let lower = result.text.index(result.text.startIndex, offsetBy: result.selection.lowerBound)
        let upper = result.text.index(result.text.startIndex, offsetBy: result.selection.upperBound)
        selection = result.selection
        select = lower..<upper
    }

    // MARK: - Suggesting links

    /// What to offer for the link being typed: items whose titles match,
    /// then -- if none is called exactly that -- a new note by that name.
    private var choices: [LinkChoice] {
        guard let completion else { return [] }
        let candidates = allItems.filter { $0 != item && !$0.title.isEmpty && !$0.isTrashed }
        let byKey = Dictionary(candidates.map { (WikiLinks.key($0.title), $0) }, uniquingKeysWith: { first, _ in first })
        var result = WikiLinkCompletion.rank(candidates.map(\.title), for: completion.query, limit: 6)
            .compactMap { byKey[WikiLinks.key($0)].map(LinkChoice.existing) }
        let typed = completion.query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, byKey[WikiLinks.key(typed)] == nil {
            result.append(.new(typed))
        }
        return result
    }

    private func updateCompletion(at cursor: String.Index?) {
        let found = cursor.flatMap { WikiLinkCompletion.context(in: item.body, cursor: $0) }
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
        select = done.cursor..<done.cursor
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

/// Bold, italics, code, link, heading, lists, checkbox, quote.
struct FormatButtons: View {
    let apply: (MarkdownFormatting.Style) -> Void

    var body: some View {
        button(.bold, "Bold", "bold", key: "b")
        button(.italic, "Italic", "italic", key: "i")
        button(.code, "Code", "chevron.left.forwardslash.chevron.right")
        button(.link, "Link", "link", key: "k")
        button(.heading, "Heading", "number")
        button(.bulletList, "Bulleted List", "list.bullet")
        button(.numberedList, "Numbered List", "list.number")
        button(.checkbox, "Checkbox", "checklist")
        button(.quote, "Quote", "text.quote")
    }

    private func button(_ style: MarkdownFormatting.Style, _ title: String, _ symbol: String,
                        key: KeyEquivalent? = nil) -> some View {
        Button {
            apply(style)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .help(title)
        .modifier(OptionalShortcut(key: key))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
