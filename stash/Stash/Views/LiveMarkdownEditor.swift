import SwiftUI
import StashCore
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
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

            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes(Self.baseAttributes, range: whole)
            for span in MarkdownStyling.spans(in: text) {
                let range = NSRange(location: span.range.lowerBound, length: span.range.count)
                guard range.location + range.length <= storage.length else { continue }
                apply(span.style, to: range, in: storage, active: active)
            }
            storage.endEditing()
        }

        /// Whether the selection has moved onto other lines, which shows different marks.
        func needsRestyle(for selection: NSRange, in text: String) -> Bool {
            let selected = selection.location..<(selection.location + selection.length)
            return MarkdownStyling.lines(touching: selected, in: text) != activeLines
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
            }
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
extension LiveMarkdownEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.typingAttributes = Coordinator.baseAttributes
        textView.string = text
        if let storage = textView.textStorage {
            context.coordinator.restyle(storage, selection: textView.selectedRange())
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        if context.coordinator.isOutsideChange(text, shown: textView.string) {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.restyle(storage, selection: textView.selectedRange())
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
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
        send(textView.string)
        // Mid-way through composing a character (Japanese, accents): style it after.
        guard !textView.hasMarkedText() else { return }
        restyle(storage, selection: textView.selectedRange())
        textView.typingAttributes = Self.baseAttributes
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if needsRestyle(for: selection, in: textView.string) { restyle(storage, selection: selection) }
        textView.typingAttributes = Self.baseAttributes
        report(selection: selection, in: textView.string)
    }
}
#else
extension LiveMarkdownEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.typingAttributes = Coordinator.baseAttributes
        textView.text = text
        context.coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.isOutsideChange(text, shown: textView.text) {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.restyle(textView.textStorage, selection: textView.selectedRange)
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
        textView.typingAttributes = Self.baseAttributes
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let selection = textView.selectedRange
        if needsRestyle(for: selection, in: textView.text) { restyle(textView.textStorage, selection: selection) }
        textView.typingAttributes = Self.baseAttributes
        report(selection: selection, in: textView.text)
    }
}
#endif
