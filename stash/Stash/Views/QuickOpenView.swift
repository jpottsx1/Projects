import SwiftData
import SwiftUI
import StashCore

/// What the quick palette is for.
enum QuickOpenMode: Identifiable {
    /// Any item or place, by name, to open (Cmd-O).
    case open
    /// A category to file these items in (Quick File, Control-Cmd-M).
    case file([Item])

    var id: String {
        switch self {
        case .open: "open"
        case .file(let items): "file" + items.map(\.uuid.uuidString).joined()
        }
    }
}

/// Type a little of a name, then Return: an item or a place to open, or a
/// category to file things in.
struct QuickOpenView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let mode: QuickOpenMode
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Choice: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let action: () -> Void
    }

    var body: some View {
        let choices = matches
        VStack(spacing: 0) {
            HStack {
                Image(systemName: isFiling ? "folder" : "magnifyingglass").foregroundStyle(.secondary)
                TextField(isFiling ? "Move to category…" : "Open item or list…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(choices) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(choices.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: text) { highlighted = 0 }
                    .accessibilityIdentifier("quickOpenField")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        Button {
                            choice.action()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: choice.icon).foregroundStyle(.tint).frame(width: 20)
                                Text(choice.title).lineLimit(1)
                                Spacer()
                                Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
        .sheetSize(minWidth: 520, minHeight: 380)
        .onAppear { focused = true }
    }

    private var isFiling: Bool {
        if case .file = mode { return true }
        return false
    }

    private func choose(_ choices: [Choice]) {
        guard choices.indices.contains(highlighted) else { return }
        choices[highlighted].action()
        dismiss()
    }

    private var matches: [Choice] {
        let categories = library.allCategories()
        switch mode {
        case .file(let items):
            var choices = categories.map { category in
                Choice(id: category.uuid.uuidString, title: category.path, detail: "", icon: "folder") {
                    library.file(items, in: category)
                }
            }
            choices.insert(Choice(id: "none", title: "No Category", detail: "", icon: "tray") {
                library.file(items, in: nil)
            }, at: 0)
            return text.isEmpty ? choices : QuickOpen.rank(choices, query: text, name: \.title)
        case .open:
            var places: [Choice] = [
                place("Inbox", "tray.and.arrow.down", .inbox), place("All Items", "tray.full", .all),
                place("Favorites", "star", .favorites), place("Recents", "clock", .recents),
                place("Unfiled", "questionmark.folder", .unfiled), place("Tasks", "checklist", .tasks), place("Read Later", "book", .readLater),
                place("Timeline", "calendar", .timeline), place("Templates", "doc.on.doc", .templates),
                place("Trash", "trash", .trash),
            ]
            places += categories.map { place($0.path, "folder", .category($0)) }
            places += library.itemLists().map { place($0.name, "list.bullet.rectangle", .list($0)) }
            places += library.smartFiltersInOrder().map { place($0.name, "line.3.horizontal.decrease.circle", .smartFilter($0)) }
            places += library.feeds().map { place($0.title, "dot.radiowaves.up.forward", .feed($0)) }
            places += ((try? library.context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)]))) ?? [])
                .map { place("#" + $0.name, "number", .tag($0)) }
            guard !text.isEmpty else { return Array(places.prefix(12)) }
            let items = library.find("", limit: .max).map { item in
                Choice(id: item.uuid.uuidString, title: item.displayTitle, detail: item.kind.rawValue.capitalized,
                       icon: item.systemImage) { library.show(item) }
            }
            return QuickOpen.rank(places + items, query: text, name: \.title)
        }
    }

    private func place(_ title: String, _ icon: String, _ selection: SidebarSelection) -> Choice {
        Choice(id: "place-" + title + icon, title: title, detail: "", icon: icon) {
            library.sidebar = selection
        }
    }
}
