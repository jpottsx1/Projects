import SwiftUI
import StashCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

/// A note's Markdown, shown formatted as it's typed, as Typora does:
/// headings large, bold bold, links tinted, and the marks themselves --
/// `**`, `#`, `](url)` -- tucked away except on the line being edited, so
/// they're there to change but not in the way. The text is still plain
/// Markdown; only how it looks changes.
struct LiveMarkdownEditor {
    @Binding var text: String
    /// Set to move the cursor or select some text; cleared once done.
    @Binding var select: Range<String.Index>?
    var onCursorMoved: (String.Index?) -> Void
    /// The selection as character offsets; empty for a cursor.
    var onSelectionChanged: (Range<Int>) -> Void
    /// A picture's file, from its `![](source)`.
    var pictureURL: (String) -> URL? = { _ in nil }
    /// Stores a pasted or dropped picture (its data and file extension)
    /// and returns the Markdown to put in the note.
    var addPicture: (Data, String) -> String? = { _, _ in nil }
    /// Typora's focus mode: everything but the paragraph being written is dimmed.
    var focusMode = false
    /// Room either side of the text.
    var margin: CGFloat = 12
    /// Tab (false) or Shift-Tab (true) on a Mac: indents a list line, if
    /// the cursor's on one; returns whether it did.
    var onIndent: ((Bool) -> Bool)?
    /// Arrows, Return, Tab and Escape while suggestions are showing (`[[`
    /// links, `/` commands): true if the suggestions took the key.
    var onSuggestionKey: ((SuggestionKey) -> Bool)?

    enum SuggestionKey { case up, down, accept, cancel }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: LiveMarkdownEditor
        /// The lines whose marks are showing, to restyle only when they change.
        private var activeLines: Range<Int>?
        private var styling = false
        /// Text this editor has just handed up. SwiftUI can come back with
        /// one of these a moment late, after more has been typed; putting
        /// it back would lose the typing, so it's recognised and ignored.
        private var recentlySent: [String] = []
        /// Pictures shown in place of their `![](…)` lines: where, what, how big.
        private var pictures: [(range: NSRange, image: PlatformImage, size: CGSize)] = []
        private var imageCache: [URL: PlatformImage] = [:]
        /// How wide pictures can be: the text's width.
        var availableWidth: CGFloat = 500

        func send(_ text: String) {
            recentlySent.append(text)
            if recentlySent.count > 30 { recentlySent.removeFirst(recentlySent.count - 30) }
            parent.text = text
        }

        /// Whether `text` is a change from elsewhere -- a formatting button,
        /// a link suggestion -- rather than this editor's own typing coming back.
        func isOutsideChange(_ text: String, shown: String) -> Bool {
            text != shown && !recentlySent.contains(text)
        }

        init(_ parent: LiveMarkdownEditor) {
            self.parent = parent
        }

        // MARK: - Styling

        static let bodySize: CGFloat = {
            #if os(macOS)
            NSFont.systemFontSize + 2
            #else
            UIFont.preferredFont(forTextStyle: .body).pointSize
            #endif
        }()

        static var baseAttributes: [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 6
            return [.font: PlatformFont.systemFont(ofSize: bodySize), .foregroundColor: PlatformColor.labelColor,
                    .paragraphStyle: paragraph]
        }

        /// Styles all the text, showing marks on the lines `selection` touches.
        func restyle(_ storage: NSTextStorage, selection: NSRange) {
            guard !styling else { return }
            styling = true
            defer { styling = false }
            let text = storage.string
            let selected = selection.location..<(selection.location + selection.length)
            let active = MarkdownStyling.lines(touching: selected, in: text)
            activeLines = active

            pictures = []
            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes(Self.baseAttributes, range: whole)
            for span in MarkdownStyling.spans(in: text) {
                let range = NSRange(location: span.range.lowerBound, length: span.range.count)
                guard range.location + range.length <= storage.length else { continue }
                apply(span.style, to: range, in: storage, active: active)
            }
            styledFocusMode = parent.focusMode
            if parent.focusMode {
                let paragraph = MarkdownStyling.paragraph(touching: selected, in: text)
                focusedParagraph = paragraph
                dimOutside(paragraph, in: storage)
            } else {
                focusedParagraph = nil
            }
            storage.endEditing()
        }

        /// Whether the selection has moved onto other lines, which shows different marks.
        func needsRestyle(for selection: NSRange, in text: String) -> Bool {
            let selected = selection.location..<(selection.location + selection.length)
            if parent.focusMode, MarkdownStyling.paragraph(touching: selected, in: text) != focusedParagraph { return true }
            return MarkdownStyling.lines(touching: selected, in: text) != activeLines
        }

        private var focusedParagraph: Range<Int>?
        /// The focus mode the text was last styled for.
        var styledFocusMode = false

        /// Dims all but the paragraph being written, leaving hidden marks hidden.
        private func dimOutside(_ paragraph: Range<Int>, in storage: NSTextStorage) {
            let dim = PlatformColor.tertiaryLabelColor
            for range in [0..<paragraph.lowerBound, paragraph.upperBound..<storage.length] where !range.isEmpty {
                let nsRange = NSRange(location: range.lowerBound, length: range.count)
                storage.enumerateAttribute(.foregroundColor, in: nsRange) { value, part, _ in
                    if (value as? PlatformColor) != PlatformColor.clear {
                        storage.addAttribute(.foregroundColor, value: dim, range: part)
                    }
                }
            }
        }

        private func apply(_ style: MarkdownStyling.Style, to range: NSRange, in storage: NSTextStorage, active: Range<Int>) {
            let tint = PlatformColor.controlAccentColorCompatible
            switch style {
            case .heading(let level):
                let scale: CGFloat = [1.7, 1.4, 1.2, 1.1, 1.05, 1.0][min(level, 6) - 1]
                storage.addAttribute(.font, value: PlatformFont.systemFont(ofSize: Self.bodySize * scale, weight: .bold), range: range)
            case .marker:
                let visible = range.location >= active.lowerBound && range.location < max(active.upperBound, active.lowerBound + 1)
                if visible {
                    storage.addAttribute(.foregroundColor, value: PlatformColor.tertiaryLabelColor, range: range)
                } else {
                    // Out of the way: tiny and see-through, but still there to edit.
                    storage.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 0.1), range: range)
                    storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
                }
            case .bold:
                addTrait(.bold, to: range, in: storage)
            case .italic:
                addTrait(.italic, to: range, in: storage)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: range)
            case .code, .codeBlock:
                storage.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: Self.bodySize * 0.92, weight: .regular), range: range)
                storage.addAttribute(.backgroundColor, value: PlatformColor.secondaryLabelColor.withAlphaComponent(0.12), range: range)
            case .link:
                storage.addAttribute(.foregroundColor, value: tint, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .wikiLink:
                storage.addAttribute(.foregroundColor, value: tint, range: range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: range)
                addTrait(.italic, to: range, in: storage)
            case .listMarker, .rule:
                storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: range)
            case .task(let done):
                storage.addAttribute(.foregroundColor, value: done ? tint : PlatformColor.secondaryLabelColor, range: range)
            case .toggleTitle:
                addTrait(.bold, to: range, in: storage)
                storage.addAttribute(.foregroundColor, value: tint, range: range)
            case .tableRow:
                // Fixed-width, so the columns of a tidied table line up.
                storage.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: Self.bodySize * 0.92, weight: .regular), range: range)
            case .image(let source, let width):
                let onLine = range.location >= active.lowerBound && range.location < max(active.upperBound, active.lowerBound + 1)
                guard !onLine, let image = image(for: source) else {
                    storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: range)
                    return
                }
                // The Markdown tucked away, with room above it for the picture.
                let size = fittedSize(of: image, limit: width)
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacingBefore = size.height + 6
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
                storage.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 0.1), range: range)
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
                pictures.append((range, image, size))
            }
        }

        private func image(for source: String) -> PlatformImage? {
            guard let url = parent.pictureURL(source), url.isFileURL else { return nil }
            if let cached = imageCache[url] { return cached }
            #if os(macOS)
            let image = NSImage(contentsOf: url)
            #else
            let image = UIImage(contentsOfFile: url.path)
            #endif
            if let image { imageCache[url] = image }
            return image
        }

        /// The picture's size in the note: no wider than the text, or than
        /// the width it's been limited to, and not too tall.
        private func fittedSize(of image: PlatformImage, limit: Int? = nil) -> CGSize {
            let size = image.size
            guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
            let widest = min(max(availableWidth, 50), limit.map(CGFloat.init) ?? .greatestFiniteMagnitude)
            let tallest: CGFloat = limit == nil ? 360 : .greatestFiniteMagnitude
            let scale = min(1, widest / size.width, tallest / size.height)
            return CGSize(width: size.width * scale, height: size.height * scale)
        }

        /// Puts each picture in the room left above its line.
        func layoutPictures(in textView: PictureTextView) {
            for view in textView.pictureViews { view.removeFromSuperview() }
            textView.pictureViews = []
            guard let (layoutManager, container) = textView.lineLayout else { return }
            layoutManager.ensureLayout(for: container)
            let origin = textView.textOrigin
            for picture in pictures {
                let glyphs = layoutManager.glyphRange(forCharacterRange: picture.range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let frame = CGRect(x: origin.x + container.lineFragmentPadding, y: origin.y + line.minY,
                                   width: picture.size.width, height: picture.size.height)
                textView.addPicture(picture.image, frame: frame)
            }
        }

        /// A picture pasted or dropped in, on a line of its own.
        func insertPicture(_ data: Data, fileExtension: String, into textView: PictureTextView) {
            guard let markdown = parent.addPicture(data, fileExtension) else { return }
            textView.insertOwnLine(markdown)
        }

        private enum Trait { case bold, italic }

        private func addTrait(_ trait: Trait, to range: NSRange, in storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                guard let font = value as? PlatformFont else { return }
                #if os(macOS)
                var traits = font.fontDescriptor.symbolicTraits
                traits.insert(trait == .bold ? .bold : .italic)
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                let changed = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                #else
                var traits = font.fontDescriptor.symbolicTraits
                traits.insert(trait == .bold ? .traitBold : .traitItalic)
                let changed = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
                #endif
                storage.addAttribute(.font, value: changed, range: part)
            }
        }

        // MARK: - Reporting

        func report(selection: NSRange, in text: String) {
            guard let range = Range(selection, in: text) else { return }
            parent.onCursorMoved(range.isEmpty ? range.lowerBound : nil)
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            parent.onSelectionChanged(start..<(start + text.distance(from: range.lowerBound, to: range.upperBound)))
        }
    }
}

extension PlatformColor {
    static var controlAccentColorCompatible: PlatformColor {
        #if os(macOS)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }
}

#if os(iOS)
/// The Mac's names for the text colours, so the styling reads the same on both.
extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
}
#endif

#if os(macOS)
/// The text view, able to show pictures over the text and to take pasted
/// or dropped pictures.
final class PictureTextView: NSTextView {
    var pictureViews: [NSView] = []
    var onPicture: ((Data, String) -> Void)?

    var textOrigin: CGPoint { textContainerOrigin }

    /// TextKit 1's layout, which says where each line is.
    var lineLayout: (NSLayoutManager, NSTextContainer)? {
        guard let layoutManager, let textContainer else { return nil }
        return (layoutManager, textContainer)
    }

    func addPicture(_ image: NSImage, frame: CGRect) {
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityIdentifier("notePicture")
        view.setAccessibilityLabel("Picture")
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        addSubview(view)
        pictureViews.append(view)
    }

    func insertOwnLine(_ text: String) {
        let selection = selectedRange()
        let string = self.string as NSString
        let before = selection.location > 0 && string.character(at: selection.location - 1) != 0x0A ? "\n" : ""
        insertText(before + text + "\n", replacementRange: selection)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil, let data = Self.pictureData(from: pasteboard) {
            onPicture?(data, "png")
        } else {
            super.paste(sender)
        }
    }

    /// The pictures shown over the text are part of the note, so they're
    /// offered to VoiceOver with it.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + pictureViews
    }

    /// A plain-text view turns Paste off when there's only a picture to
    /// paste; pictures are welcome here.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.pictureData(from: .general) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            for url in urls {
                if let data = try? Data(contentsOf: url) { onPicture?(data, url.pathExtension.lowercased()) }
            }
            return true
        }
        return super.performDragOperation(sender)
    }

    /// A picture on the pasteboard, as PNG.
    static func pictureData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension LiveMarkdownEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, which says where each line is, for placing pictures.
        let textView = PictureTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("noteEditor")
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: margin, height: 12)
        textView.drawsBackground = false
        textView.registerForDraggedTypes([.fileURL])
        textView.typingAttributes = Coordinator.baseAttributes
        textView.string = text
        let coordinator = context.coordinator
        textView.onPicture = { [weak textView] data, ext in
            guard let textView else { return }
            coordinator.insertPicture(data, fileExtension: ext, into: textView)
        }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak textView] _ in
            MainActor.assumeIsolated {
                guard let textView, let storage = textView.textStorage else { return }
                let width = textView.bounds.width - 2 * textView.textContainerInset.width - 10
                guard abs(width - coordinator.availableWidth) > 1 else { return }
                coordinator.availableWidth = width
                coordinator.restyle(storage, selection: textView.selectedRange())
                coordinator.layoutPictures(in: textView)
            }
        }
        if let storage = textView.textStorage {
            context.coordinator.restyle(storage, selection: textView.selectedRange())
            DispatchQueue.main.async { context.coordinator.layoutPictures(in: textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PictureTextView, let storage = textView.textStorage else { return }
        // The margins changed: pictures fit the new width.
        if textView.textContainerInset.width != margin {
            textView.textContainerInset = NSSize(width: margin, height: 12)
            context.coordinator.availableWidth = textView.bounds.width - 2 * margin - 10
            context.coordinator.restyle(storage, selection: textView.selectedRange())
            context.coordinator.layoutPictures(in: textView)
        }
        if context.coordinator.styledFocusMode != focusMode {
            context.coordinator.restyle(storage, selection: textView.selectedRange())
        }
        if context.coordinator.isOutsideChange(text, shown: textView.string) {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.restyle(storage, selection: textView.selectedRange())
            context.coordinator.layoutPictures(in: textView)
        }
        if let target = select {
            let range = NSRange(target, in: text)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.async { self.select = nil }
        }
    }
}

extension LiveMarkdownEditor.Coordinator: NSTextViewDelegate {
    /// Tab and Shift-Tab on a list line nest it, as in other outliners.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Suggestions showing take the arrows, Return, Tab and Escape first.
        if let onSuggestionKey = parent.onSuggestionKey {
            let key: LiveMarkdownEditor.SuggestionKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): .accept
            case #selector(NSResponder.cancelOperation(_:)): .cancel
            default: nil
            }
            if let key, onSuggestionKey(key) { return true }
        }
        guard selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)),
              let onIndent = parent.onIndent else { return false }
        return onIndent(selector == #selector(NSResponder.insertBacktab(_:)))
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? PictureTextView, let storage = textView.textStorage else { return }
        send(textView.string)
        // Mid-way through composing a character (Japanese, accents): style it after.
        guard !textView.hasMarkedText() else { return }
        restyle(storage, selection: textView.selectedRange())
        layoutPictures(in: textView)
        textView.typingAttributes = Self.baseAttributes
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? PictureTextView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if needsRestyle(for: selection, in: textView.string) {
            restyle(storage, selection: selection)
            layoutPictures(in: textView)
        }
        textView.typingAttributes = Self.baseAttributes
        report(selection: selection, in: textView.string)
    }
}
#else
/// The text view, able to show pictures over the text and to take pasted
/// pictures.
final class PictureTextView: UITextView {
    var pictureViews: [UIView] = []
    /// The text system, kept here: a text view made from a container
    /// doesn't keep its storage alive itself.
    private var keptStorage: NSTextStorage?

    /// A text view on TextKit 1, which says where each line is. Built by
    /// hand rather than with `UITextView(usingTextLayoutManager: false)`:
    /// that's a factory method, which skips this class's own setup, and the
    /// first use of `pictureViews` then crashed.
    static func make() -> PictureTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = PictureTextView(frame: .zero, textContainer: container)
        view.keptStorage = storage
        return view
    }
    var onPicture: ((Data, String) -> Void)?
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    var textOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    /// TextKit 1's layout, which says where each line is.
    var lineLayout: (NSLayoutManager, NSTextContainer)? { (layoutManager, textContainer) }

    func addPicture(_ image: UIImage, frame: CGRect) {
        let view = UIImageView(frame: frame)
        view.image = image
        view.contentMode = .scaleAspectFit
        view.accessibilityIdentifier = "notePicture"
        view.isAccessibilityElement = true
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
        addSubview(view)
        pictureViews.append(view)
    }

    func insertOwnLine(_ text: String) {
        let selection = selectedRange
        let string = self.text as NSString
        let before = selection.location > 0 && string.character(at: selection.location - 1) != 0x0A ? "\n" : ""
        insertText(before + text + "\n")
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if !pasteboard.hasStrings, let data = pasteboard.image?.pngData() {
            onPicture?(data, "png")
        } else {
            super.paste(sender)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 1 {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}

extension LiveMarkdownEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> PictureTextView {
        let textView = PictureTextView.make()
        textView.delegate = context.coordinator
        textView.accessibilityIdentifier = "noteEditor"
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: margin, bottom: 12, right: margin)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.typingAttributes = Coordinator.baseAttributes
        textView.text = text
        let coordinator = context.coordinator
        textView.onPicture = { [weak textView] data, ext in
            guard let textView else { return }
            coordinator.insertPicture(data, fileExtension: ext, into: textView)
        }
        textView.onWidthChange = { [weak textView] in
            guard let textView else { return }
            coordinator.availableWidth = textView.bounds.width - textView.textContainerInset.left
                - textView.textContainerInset.right - 2 * textView.textContainer.lineFragmentPadding
            coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
            coordinator.layoutPictures(in: textView)
        }
        context.coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
        return textView
    }

    func updateUIView(_ textView: PictureTextView, context: Context) {
        context.coordinator.parent = self
        if textView.textContainerInset.left != margin {
            textView.textContainerInset = UIEdgeInsets(top: 12, left: margin, bottom: 12, right: margin)
            textView.onWidthChange?()
        }
        if context.coordinator.styledFocusMode != focusMode {
            context.coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
        }
        if context.coordinator.isOutsideChange(text, shown: textView.text) {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
            context.coordinator.layoutPictures(in: textView)
        }
        if let target = select {
            textView.selectedRange = NSRange(target, in: text)
            textView.scrollRangeToVisible(textView.selectedRange)
            DispatchQueue.main.async { self.select = nil }
        }
    }
}

extension LiveMarkdownEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        send(textView.text)
        // Mid-way through composing a character (Japanese, accents): style it after.
        guard textView.markedTextRange == nil else { return }
        restyle(textView.textStorage, selection: textView.selectedRange)
        if let textView = textView as? PictureTextView { layoutPictures(in: textView) }
        textView.typingAttributes = Self.baseAttributes
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let selection = textView.selectedRange
        if needsRestyle(for: selection, in: textView.text) {
            restyle(textView.textStorage, selection: selection)
            if let textView = textView as? PictureTextView { layoutPictures(in: textView) }
        }
        textView.typingAttributes = Self.baseAttributes
        report(selection: selection, in: textView.text)
    }
}
#endif
