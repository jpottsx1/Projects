import SwiftUI
import StashCore

/// A text editor that says where its cursor and selection are, so `[[`
/// can be completed and the formatting buttons know what to change.
///
/// From iOS 18 (and on every macOS Stash runs on) the system editor
/// reports its selection, and can be told what to select after a change.
/// On iOS 17.5 it says neither, so the cursor is taken to be wherever the
/// text last changed -- right while typing; after a suggestion or some
/// formatting is put in, the cursor may land elsewhere.
struct NoteTextEditor: View {
    @Binding var text: String
    /// Set to move the cursor or select some text (honoured from iOS 18,
    /// and on the Mac); cleared once done.
    @Binding var select: Range<String.Index>?
    /// Nil when a stretch of text is selected rather than a cursor placed.
    var onCursorMoved: (String.Index?) -> Void
    /// The selection as character offsets into the text; empty for a cursor.
    var onSelectionChanged: (Range<Int>) -> Void = { _ in }

    var body: some View {
        if #available(iOS 18, *) {
            SelectionReportingEditor(text: $text, select: $select, onCursorMoved: onCursorMoved,
                                     onSelectionChanged: onSelectionChanged)
        } else {
            TextEditor(text: $text)
                .onChange(of: text) { old, new in
                    let point = WikiLinkCompletion.editPoint(from: old, to: new)
                    onCursorMoved(point)
                    let offset = new.distance(from: new.startIndex, to: point)
                    onSelectionChanged(offset..<offset)
                }
        }
    }
}

@available(iOS 18, *)
private struct SelectionReportingEditor: View {
    @Binding var text: String
    @Binding var select: Range<String.Index>?
    var onCursorMoved: (String.Index?) -> Void
    var onSelectionChanged: (Range<Int>) -> Void
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .onChange(of: selection) { _, selection in
                guard case .selection(let range)? = selection?.indices,
                      range.upperBound <= text.endIndex else {
                    onCursorMoved(nil)
                    return
                }
                // Only a plain cursor counts; a selected stretch of text isn't typing.
                onCursorMoved(range.isEmpty ? range.lowerBound : nil)
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                onSelectionChanged(start..<(start + text.distance(from: range.lowerBound, to: range.upperBound)))
            }
            .onChange(of: select) { _, target in
                guard let target else { return }
                selection = target.isEmpty ? TextSelection(insertionPoint: target.lowerBound) : TextSelection(range: target)
                select = nil
            }
    }
}

/// One suggestion: an item to link to, or a new note named what was typed.
enum LinkChoice: Hashable {
    case existing(Item)
    case new(String)

    var title: String {
        switch self {
        case .existing(let item): item.title
        case .new(let title): title
        }
    }

    var label: String {
        switch self {
        case .existing(let item): item.displayTitle
        case .new(let title): "New note “\(title)”"
        }
    }

    var systemImage: String {
        switch self {
        case .existing(let item): item.systemImage
        case .new: "plus.circle"
        }
    }
}

/// The list under the editor while a `[[link]]` is being typed. Tap one,
/// or on a keyboard use the arrows and Return or Tab; Escape closes it.
struct LinkSuggestions: View {
    let choices: [LinkChoice]
    let highlighted: Int
    let onPick: (LinkChoice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    onPick(choice)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: choice.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(choice.label)
                            .lineLimit(1)
                        Spacer()
                        #if os(macOS)
                        if index == highlighted {
                            Text("↩").foregroundStyle(.secondary)
                        }
                        #endif
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(index == highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial)
    }
}
