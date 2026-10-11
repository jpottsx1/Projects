import SwiftUI
import StashCore

/// A text editor that says where its cursor is, so `[[` can be completed.
///
/// From iOS 18 (and on every macOS Stash runs on) the system editor
/// reports its selection, and can be told where to put the cursor after a
/// suggestion is inserted. On iOS 17.5 it says neither, so the cursor is
/// taken to be wherever the text last changed -- right while typing; after
/// a suggestion is inserted, the cursor may land elsewhere.
struct NoteTextEditor: View {
    @Binding var text: String
    /// Set to move the cursor (honoured from iOS 18, and on the Mac); cleared once done.
    @Binding var moveCursorTo: String.Index?
    /// Nil when a stretch of text is selected rather than a cursor placed.
    var onCursorMoved: (String.Index?) -> Void

    var body: some View {
        if #available(iOS 18, *) {
            SelectionReportingEditor(text: $text, moveCursorTo: $moveCursorTo, onCursorMoved: onCursorMoved)
        } else {
            TextEditor(text: $text)
                .onChange(of: text) { old, new in
                    onCursorMoved(WikiLinkCompletion.editPoint(from: old, to: new))
                }
        }
    }
}

@available(iOS 18, *)
private struct SelectionReportingEditor: View {
    @Binding var text: String
    @Binding var moveCursorTo: String.Index?
    var onCursorMoved: (String.Index?) -> Void
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .onChange(of: selection) { _, selection in
                // Only a plain cursor counts; a selected stretch of text isn't typing.
                if case .selection(let range)? = selection?.indices, range.isEmpty {
                    onCursorMoved(range.lowerBound)
                } else {
                    onCursorMoved(nil)
                }
            }
            .onChange(of: moveCursorTo) { _, target in
                guard let target else { return }
                selection = TextSelection(insertionPoint: target)
                moveCursorTo = nil
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
