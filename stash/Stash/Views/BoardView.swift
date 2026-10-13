import SwiftData
import SwiftUI
import StashCore

/// What a board's columns are.
enum BoardGrouping: Hashable {
    case label
    /// The top-level categories: an item goes in the one it's in, or inside.
    case category
    /// One of your own choice fields.
    case field(UUID)

    var stored: String {
        switch self {
        case .label: "label"
        case .category: "category"
        case .field(let id): "field:" + id.uuidString
        }
    }

    init(stored: String) {
        if stored.hasPrefix("field:"), let id = UUID(uuidString: String(stored.dropFirst(6))) {
            self = .field(id)
        } else {
            self = stored == "category" ? .category : .label
        }
    }
}

/// The items as cards in columns, Kanban-style: by label, top-level
/// category or a choice field. Dragging a card to another column changes
/// that about it.
struct BoardView: View {
    @Environment(Library.self) private var library
    @Query(filter: #Predicate<ItemCategory> { $0.parent == nil }, sort: \ItemCategory.name)
    private var rootCategories: [ItemCategory]
    @Query(sort: \FieldDefinition.order) private var fields: [FieldDefinition]
    @AppStorage("boardGrouping") private var groupingStored = BoardGrouping.label.stored
    let items: [Item]
    let menu: (Item) -> AnyView

    private struct Column: Identifiable {
        /// What the column stands for, as stored: a label's number, a
        /// category's uuid, a choice; "" for none.
        let id: String
        let title: String
        let color: Color?
        var items: [Item]
    }

    private var grouping: BoardGrouping {
        let chosen = BoardGrouping(stored: groupingStored)
        // A field that's gone, or isn't a choice any more, falls back to labels.
        if case .field(let id) = chosen, fields.first(where: { $0.uuid == id })?.kind != .choice { return .label }
        return chosen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Columns", selection: $groupingStored) {
                    Text("Label").tag(BoardGrouping.label.stored)
                    Text("Category").tag(BoardGrouping.category.stored)
                    ForEach(fields.filter { $0.kind == .choice }) { field in
                        Text(field.name).tag(BoardGrouping.field(field.uuid).stored)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("boardGrouping")
                Spacer()
                Text("Drag a card to another column to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns()) { column in
                        columnView(column)
                    }
                }
                .padding()
            }
        }
    }

    private func columns() -> [Column] {
        switch grouping {
        case .label:
            return ItemLabel.allCases.map { label in
                Column(id: String(label.rawValue), title: label == .none ? "No Label" : label.name,
                       color: label == .none ? nil : label.color, items: items.filter { $0.label == label })
            }
        case .category:
            func root(_ item: Item) -> ItemCategory? {
                var category = item.category
                while let parent = category?.parent { category = parent }
                return category
            }
            var columns = [Column(id: "", title: "No Category", color: nil, items: items.filter { $0.category == nil })]
            for category in rootCategories {
                columns.append(Column(id: category.uuid.uuidString, title: category.name, color: nil,
                                      items: items.filter { root($0) == category }))
            }
            return columns
        case .field(let id):
            guard let field = fields.first(where: { $0.uuid == id }) else { return [] }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.uuid, library.value(of: field, for: $0)) })
            let choices = field.choiceList
            var columns = [Column(id: "", title: "No \(field.name)", color: nil,
                                  items: items.filter { !choices.contains(values[$0.uuid] ?? "") })]
            for choice in choices {
                columns.append(Column(id: choice, title: choice, color: nil, items: items.filter { values[$0.uuid] == choice }))
            }
            return columns
        }
    }

    private func columnView(_ column: Column) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let color = column.color {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text(column.title).font(.headline)
                Text("\(column.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.items) { item in
                        BoardCard(item: item, isSelected: library.listSelection.contains(item))
                            .onTapGesture { library.select([item]) }
                            .contextMenu { menu(item) }
                            .draggable(item.uuid.uuidString)
                            #if os(iOS)
                            .hoverEffect(.lift)
                            #endif
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { ids, _ in
            let moved = library.items(withIDs: ids.compactMap(UUID.init(uuidString:)))
            guard !moved.isEmpty else { return false }
            move(moved, to: column.id)
            return true
        }
        .accessibilityIdentifier("boardColumn-\(column.title)")
    }

    /// Changes items to belong in a column.
    private func move(_ moved: [Item], to columnID: String) {
        switch grouping {
        case .label:
            library.setLabel(moved, ItemLabel(rawValue: Int(columnID) ?? 0) ?? .none)
        case .category:
            let category = rootCategories.first { $0.uuid.uuidString == columnID }
            // Already somewhere inside the column's category: left where it is.
            library.file(moved.filter { item in
                guard let category else { return item.category != nil }
                return !category.contains(item.category)
            }, in: category)
        case .field(let id):
            guard let field = fields.first(where: { $0.uuid == id }) else { return }
            library.setValue(columnID, of: field, for: moved)
        }
    }
}

private struct BoardCard: View {
    let item: Item
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.isLocked ? "lock.fill" : item.systemImage)
                    .foregroundStyle(.tint)
                Text(item.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if item.isUnread {
                    Circle().fill(.blue).frame(width: 7, height: 7)
                }
            }
            if !item.listSubtitle.isEmpty {
                Text(item.listSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !(item.tags ?? []).isEmpty {
                Text(item.sortedTags.map { "#" + $0.name }.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                                                                lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-\(item.displayTitle)")
    }
}
