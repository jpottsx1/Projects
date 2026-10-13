#if os(macOS)
import SwiftUI
import SwiftData
import StashCore

/// DEVONthink's Sorter: a small window that floats above other apps, with
/// the Inbox and each category to drop files, web addresses, pictures and
/// text onto, and a field to jot a note into the one chosen.
struct SorterView: View {
    @Environment(Library.self) private var library
    @Query private var categories: [ItemCategory]
    @State private var filter = ""
    @State private var chosen: ItemCategory?
    @State private var targeted: String?
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find a category", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                row(id: "inbox", title: "Inbox", icon: "tray.and.arrow.down", target: .inbox, category: nil)
                ForEach(shownCategories) { category in
                    row(id: category.uuid.uuidString, title: category.path, icon: "folder", target: .category(category), category: category)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                TextField(chosen.map { "Note in \($0.name)" } ?? "Note in Inbox", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit(jot)
                Button("Add", action: jot)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 220, idealWidth: 260, minHeight: 280, idealHeight: 420)
    }

    private var shownCategories: [ItemCategory] {
        let all = categories.filter { $0.parent == nil }.sorted(by: ItemCategory.inOrder).flatMap(\.flattened)
        return filter.isEmpty ? all : all.filter { $0.path.localizedStandardContains(filter) }
    }

    private func row(id: String, title: String, icon: String, target: ArrivalTarget, category: ItemCategory?) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(rowBackground(id: id, category: category))
            .onTapGesture { chosen = category }
            .onDrop(of: Library.droppableTypes, isTargeted: Binding(
                get: { targeted == id },
                set: { targeted = $0 ? id : (targeted == id ? nil : targeted) })
            ) { providers in
                Task { await library.importDropped(providers, into: target) }
                return true
            }
            .help("Drop files, web addresses, pictures or text here")
    }

    private func rowBackground(id: String, category: ItemCategory?) -> some View {
        Group {
            if targeted == id {
                Color.accentColor.opacity(0.35)
            } else if chosen == category {
                Color.accentColor.opacity(0.12)
            } else {
                Color.clear
            }
        }
    }

    private func jot() {
        library.jot(note, into: chosen.map(ArrivalTarget.category) ?? .inbox)
        note = ""
    }
}
#endif
