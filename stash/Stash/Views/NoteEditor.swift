import PencilKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import StashCore
#if os(iOS)
import PhotosUI
#endif

/// Markdown as text to edit, as a formatted preview, or both side by side
/// where there's room. In the preview `[[links]]` can be followed and task
/// boxes ticked; while editing, typing `[[` suggests items to link to, and
/// the formatting buttons mark up the selected text.
struct NoteEditor: View {
    @AppStorage(Library.autoLinkKey) private var autoLinksNames = false
    enum Mode: String {
        /// Formatted as it's typed (`LiveMarkdownEditor`).
        case write
        /// Notion's blocks, to move and turn into other kinds (`BlockEditor`).
        case blocks
        /// The plain Markdown.
        case edit
        case split, preview
    }

    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var item: Item
    @State private var mode: Mode
    /// The mode notes open in, from the last one chosen.
    @AppStorage("noteMode") private var preferredMode = Mode.write.rawValue
    @AppStorage("focusMode") private var focusMode = false

    /// Most recently edited first, which is the order suggestions keep.
    @Query(sort: \Item.modifiedAt, order: .reverse) private var allItems: [Item]
    @State private var completion: WikiLinkCompletion.Context?
    @State private var highlighted = 0
    @State private var select: Range<String.Index>?
    /// The selection as character offsets, for the formatting buttons.
    @State private var selection: Range<Int>?
    @State private var isChoosingPicture = false
    @State private var isRecording = false
    /// The sketch being drawn: a new one, or the one on the cursor's line.
    @State private var sketching: SketchEditing?
    /// Room either side of the text, in points.
    @AppStorage("noteMargin") private var margin = 12.0
    @AppStorage("showWordCount") private var showWordCount = false
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    init(item: Item) {
        self.item = item
        let preferred = Mode(rawValue: UserDefaults.standard.string(forKey: "noteMode") ?? "") ?? .write
        // A new, empty note opens ready to type in, however notes were last read.
        _mode = State(initialValue: item.body.isEmpty && preferred == .preview ? .write : preferred)
    }

    var body: some View {
        Group {
            switch mode {
            case .preview:
                preview
            case .write:
                liveEditor
            case .blocks:
                BlockEditor(item: item)
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
        // Here, not on their buttons: a sheet on a button in the formatting
        // bar (a toolbar above the keyboard on an iPhone) never appears.
        .sheet(item: $sketching) { editing in
            SketchEditor(drawing: editing.drawing) { drawing in
                guard let markdown = library.saveSketch(drawing, in: item) else { return }
                if let old = editing.replacing, let range = item.body.range(of: old) {
                    item.body.replaceSubrange(range, with: markdown)
                } else {
                    insertOwnLine(markdown)
                }
                library.didEdit(item)
            }
        }
        .sheet(isPresented: $isRecording) {
            RecordingSheet(note: item) { words, recording in
                // What was said, then a link to the recording itself.
                let link = "🎙 [[\(recording.title)]]"
                insertOwnLine(words.isEmpty ? link : words + "\n\n" + link)
                library.didEdit(item)
            }
        }

        .onChange(of: mode) {
            completion = nil
            preferredMode = mode.rawValue
        }
        .onAppear {
            library.beginEditing(item)
            revealFirstMatch()
        }
        .onDisappear { library.endEditing(item) }
        .toolbar {
            if mode != .preview {
                ToolbarItem {
                    outlineMenu
                }
            }
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    Text("Write").tag(Mode.write)
                    Text("Blocks").tag(Mode.blocks)
                    Text("Source").tag(Mode.edit)
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
                        extraButtons
                    }
                    .padding(.horizontal, 4)
                }
            }
            #endif
        }
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(text: item.body, onToggleTask: { line in
                item.body = MarkdownBlocks.toggleTask(onLine: line, in: item.body)
            }, pictureURL: { library.pictureURL($0, in: item) },
               autoLinks: autoLinksNames ? library.autoLinkNames(excluding: item) : [])
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Library.linkScheme else { return .systemAction }
            library.open(stashURL: url)
            return .handled
        })
    }

    #if os(iOS)
    private static let formatSpacing: CGFloat = 16
    #else
    private static let formatSpacing: CGFloat = 4
    #endif

    /// Formatted as it's typed, with the formatting buttons above it.
    private var liveEditor: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.formatSpacing) {
                    FormatButtons(apply: format)
                    extraButtons
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            Divider()
            LiveMarkdownEditor(text: $item.body, select: $select, onCursorMoved: { cursor in
                updateCompletion(at: cursor)
            }, onSelectionChanged: { range in
                selection = range
            }, pictureURL: { library.pictureURL($0, in: item) },
               addPicture: { data, ext in library.addPicture(data, fileExtension: ext, to: item) },
               focusMode: focusMode, margin: margin, onIndent: { outward in indent(outward: outward) })
            .overlay(alignment: .bottomTrailing) { wordCount }
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

    private var editor: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 2) {
                FormatButtons(apply: format)
                extraButtons
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
            .padding(.horizontal, max(10, margin - 2))
            .overlay(alignment: .bottomTrailing) { wordCount }
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

    /// The note's headings, to jump to; and focus mode.
    private var outlineMenu: some View {
        Menu {
            let headings = MarkdownOutline.headings(in: item.body)
            if headings.isEmpty {
                Text("Headings appear here")
            }
            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                Button(String(repeating: "    ", count: max(heading.level - 1, 0)) + heading.title) {
                    jump(to: heading.offset)
                }
            }
            Divider()
            Toggle("Focus Mode", isOn: $focusMode)
            Toggle("Word Count", isOn: $showWordCount)
            Picker("Margins", selection: $margin) {
                Text("Narrow").tag(12.0)
                Text("Medium").tag(60.0)
                Text("Wide").tag(140.0)
            }
        } label: {
            Label("Outline", systemImage: "list.bullet.indent")
        }
        .help("Jump to a heading, focus mode, word count and margins")
    }

    /// How many words, floating over the text's corner.
    @ViewBuilder
    private var wordCount: some View {
        if showWordCount {
            let words = LibraryStats.wordCount(item.body)
            Text(words == 1 ? "1 word" : "\(words.formatted()) words")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityIdentifier("wordCount")
        }
    }

    /// Opened from a search: the first place it matches, selected and in view.
    private func revealFirstMatch() {
        let terms = library.search.query.terms.map(\.text).filter { !$0.isEmpty }
        for term in terms {
            if let range = item.body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                let lower = item.body.distance(from: item.body.startIndex, to: range.lowerBound)
                selection = lower..<(lower + item.body[range].count)
                select = range
                return
            }
        }
    }

    /// Nests the list lines the selection touches one level in or out;
    /// false when there's no list line there (Tab then types a tab).
    @discardableResult
    private func indent(outward: Bool) -> Bool {
        let range = selection ?? (item.body.count..<item.body.count)
        let result = MarkdownFormatting.indent(item.body, selection: range, outward: outward)
        guard result.text != item.body else { return false }
        item.body = result.text
        selection = result.selection
        let lower = result.text.index(result.text.startIndex, offsetBy: min(result.selection.lowerBound, result.text.count))
        let upper = result.text.index(result.text.startIndex, offsetBy: min(result.selection.upperBound, result.text.count))
        select = lower..<upper
        return true
    }

    /// The cursor's line, its index, and where in it the cursor is.
    private var cursorLine: (index: Int, line: String, column: Int) {
        let offset = min(selection?.lowerBound ?? 0, item.body.count)
        let before = item.body.prefix(offset)
        let index = before.filter { $0 == "\n" }.count
        let lineStart = before.lastIndex(of: "\n").map { item.body.index(after: $0) } ?? item.body.startIndex
        let lineEnd = item.body[lineStart...].firstIndex(of: "\n") ?? item.body.endIndex
        let column = item.body.distance(from: lineStart, to: item.body.index(item.body.startIndex, offsetBy: offset))
        return (index, String(item.body[lineStart..<lineEnd]), column)
    }

    private func changeTable(_ change: MarkdownTable.Change) {
        let cursor = cursorLine
        guard let changed = MarkdownTable.change(item.body, line: cursor.index,
                                                 column: MarkdownTable.column(at: cursor.column, in: cursor.line), change) else { return }
        item.body = changed
    }

    /// Limits the picture on the cursor's line to a width (nil for the text's width).
    private func setPictureWidth(_ width: Int?) {
        let cursor = cursorLine
        guard let changed = MarkdownBlocks.settingPictureWidth(cursor.line, to: width) else { return }
        var lines = item.body.components(separatedBy: "\n")
        lines[cursor.index] = changed
        item.body = lines.joined(separator: "\n")
    }

    private func jump(to offset: Int) {
        let clamped = min(offset, item.body.count)
        let index = item.body.index(item.body.startIndex, offsetBy: clamped)
        selection = clamped..<clamped
        select = index..<index
    }

    /// Picture and table buttons, after the formatting ones.
    @ViewBuilder
    private var extraButtons: some View {
        #if os(iOS)
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Picture", systemImage: "photo").labelStyle(.iconOnly)
        }
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self) {
                    insertOwnLine(library.addPicture(data, fileExtension: "jpg", to: item))
                }
                self.photo = nil
            }
        }
        #else
        Button {
            isChoosingPicture = true
        } label: {
            Label("Picture", systemImage: "photo").labelStyle(.iconOnly)
        }
        .help("Add a picture")
        .fileImporter(isPresented: $isChoosingPicture, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                insertOwnLine(library.addPicture(data, fileExtension: url.pathExtension.lowercased(), to: item))
            }
        }
        #endif
        Button {
            indent(outward: true)
        } label: {
            Label("Outdent", systemImage: "decrease.indent").labelStyle(.iconOnly)
        }
        .help("Move the list item out a level (Shift-Tab)")
        Button {
            indent(outward: false)
        } label: {
            Label("Indent", systemImage: "increase.indent").labelStyle(.iconOnly)
        }
        .help("Nest the list item a level in (Tab)")
        Menu {
            Button("Small") { setPictureWidth(200) }
            Button("Medium") { setPictureWidth(400) }
            Button("Large") { setPictureWidth(640) }
            Button("Fit the Text") { setPictureWidth(nil) }
        } label: {
            Label("Picture Size", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Size of the picture on the cursor’s line")
        Button {
            sketching = sketchAtCursor() ?? SketchEditing(drawing: PKDrawing(), replacing: nil)
        } label: {
            Label("Sketch", systemImage: "pencil.and.scribble").labelStyle(.iconOnly)
        }
        .help("Draw a sketch, or change the one on the cursor’s line")
        .accessibilityIdentifier("sketchButton")
        Button {
            isRecording = true
        } label: {
            Label("Record", systemImage: "mic").labelStyle(.iconOnly)
        }
        .help("Record, and put what you say here")
        Menu {
            Button("Insert Table") { insertOwnLine(MarkdownTable.template()) }
            Button("Tidy Table") { tidyTable() }
            Divider()
            Button("Add Row Below") { changeTable(.addRowBelow) }
            Button("Delete Row") { changeTable(.deleteRow) }
            Button("Add Column After") { changeTable(.addColumnAfter) }
            Button("Delete Column") { changeTable(.deleteColumn) }
        } label: {
            Label("Table", systemImage: "tablecells").labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a table, or line up the columns of the one the cursor is in")
    }

    /// Puts `text` on lines of its own at the cursor (or the end).
    private func insertOwnLine(_ text: String) {
        var characters = Array(item.body)
        let at = min(selection?.upperBound ?? characters.count, characters.count)
        let before = at > 0 && characters[at - 1] != "\n" ? "\n" : ""
        let after = at < characters.count && characters[at] != "\n" ? "\n" : ""
        let insertion = Array(before + text + "\n" + after)
        characters.insert(contentsOf: insertion, at: at)
        item.body = String(characters)
        let end = at + insertion.count
        selection = end..<end
        let index = item.body.index(item.body.startIndex, offsetBy: min(end, item.body.count))
        select = index..<index
    }

    /// The sketch on the cursor's line, to change.
    private func sketchAtCursor() -> SketchEditing? {
        let offset = min(selection?.lowerBound ?? item.body.count, item.body.count)
        let lineStart = item.body.prefix(offset).lastIndex(of: "\n").map { item.body.index(after: $0) } ?? item.body.startIndex
        let lineEnd = item.body[lineStart...].firstIndex(of: "\n") ?? item.body.endIndex
        let line = String(item.body[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
        guard let picture = MarkdownBlocks.image(line), picture.source.hasPrefix(Library.attachmentScheme) else { return nil }
        let name = String(picture.source.dropFirst(Library.attachmentScheme.count))
        guard let drawing = library.sketchDrawing(name, in: item) else { return nil }
        return SketchEditing(drawing: drawing, replacing: line)
    }

    /// Lines up the columns of the table the cursor is in.
    private func tidyTable() {
        let offset = min(selection?.lowerBound ?? 0, item.body.count)
        let line = item.body.prefix(offset).filter { $0 == "\n" }.count
        guard let tidied = MarkdownTable.tidy(item.body, aroundLine: line) else { return }
        item.body = tidied.text
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
    /// Where a picture's source is, for showing it; nil leaves it out.
    var pictureURL: (String) -> URL? = { _ in nil }
    /// Items' names to link wherever they're mentioned; none to leave the text as it is.
    var autoLinks: [AutoLink.Name] = []

    var body: some View {
        let linked = autoLinks.isEmpty ? text : AutoLink.link(text, names: autoLinks, scheme: Library.linkScheme)
        let blocks = MarkdownBlocks.parse(WikiLinks.markdownLinks(in: linked, scheme: Library.linkScheme))
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
        case .image(let fullAlt, let source):
            let (alt, width) = MarkdownBlocks.pictureSize(fullAlt)
            if let url = pictureURL(source) {
                PictureView(url: url, maxWidth: width.map(CGFloat.init) ?? 600)
                    .accessibilityLabel(alt.isEmpty ? "Picture" : alt)
            } else {
                Label(alt.isEmpty ? "Picture" : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell).bold()
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(0..<max(header.count, row.count), id: \.self) { column in
                                inline(column < row.count ? row[column] : "")
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
        case .toggle(let title, let body, let line):
            ToggleSection(title: title) {
                MarkdownView(text: body, onToggleTask: { onToggleTask(line + $0) }, pictureURL: pictureURL, autoLinks: autoLinks)
            } label: {
                inline(title.isEmpty ? "Toggle" : title).bold()
            }
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

/// A picture in a note: a stored one from its file, or one from the web.
struct PictureView: View {
    let url: URL
    var maxWidth: CGFloat = 600

    var body: some View {
        Group {
            if url.isFileURL {
                #if os(macOS)
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                #else
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                #endif
            } else {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxWidth == 600 ? 420 : nil, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A sketch open to draw: the drawing, and the Markdown it replaces when
/// it's one already in the note.
struct SketchEditing: Identifiable {
    let id = UUID()
    var drawing: PKDrawing
    var replacing: String?
}
