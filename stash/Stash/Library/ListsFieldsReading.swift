import Foundation
import SwiftData
import StashCore

/// Lists, your own fields, and the reading queue.
extension Library {
    // MARK: - Lists

    func itemLists() -> [ItemList] {
        ((try? context.fetch(FetchDescriptor<ItemList>())) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func newList(named name: String, adding items: [Item] = []) -> ItemList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = ItemList(name: trimmed)
        context.insert(list)
        add(items, to: list)
        save()
        return list
    }

    func rename(_ list: ItemList, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        list.name = trimmed
        save()
    }

    /// The list goes; its items stay where else they are.
    func delete(_ list: ItemList) {
        if sidebar == .list(list) { sidebar = .all }
        context.delete(list)
        save()
    }

    /// Adds items to the end of a list, keeping those already in it where they are.
    func add(_ items: [Item], to list: ItemList) {
        var order = list.orderedItems.map(\.uuid)
        for item in items where !(item.lists ?? []).contains(list) {
            item.lists = (item.lists ?? []) + [list]
            order.append(item.uuid)
        }
        list.order = order
        save()
        revision += 1
    }

    func remove(_ items: [Item], from list: ItemList) {
        let ids = Set(items.map(\.uuid))
        for item in items { item.lists = (item.lists ?? []).filter { $0 != list } }
        list.order = list.order.filter { !ids.contains($0) }
        save()
        revision += 1
    }

    /// Reorders a list as the items showing were dragged.
    func move(in list: ItemList, showing visible: [Item], from offsets: IndexSet, to destination: Int) {
        var shown = visible.map(\.uuid)
        shown.move(fromOffsets: offsets, toOffset: destination)
        let hidden = list.orderedItems.map(\.uuid).filter { !shown.contains($0) }
        list.order = shown + hidden
        save()
        revision += 1
    }

    // MARK: - Fields

    func fieldDefinitions() -> [FieldDefinition] {
        ((try? context.fetch(FetchDescriptor<FieldDefinition>())) ?? [])
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    @discardableResult
    func newField(named name: String, kind: CustomField.Kind) -> FieldDefinition? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let field = FieldDefinition(name: trimmed, kind: kind, order: (fieldDefinitions().map(\.order).max() ?? -1) + 1)
        context.insert(field)
        save()
        return field
    }

    /// The field goes, and its value from every item.
    func delete(_ field: FieldDefinition) {
        let id = field.uuid
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { !$0.customFields.isEmpty }))) ?? []
        for item in items {
            var values = CustomField.decode(item.customFields)
            guard values.removeValue(forKey: id) != nil else { continue }
            item.customFields = CustomField.encode(values)
            reindex(item)
        }
        context.delete(field)
        save()
        runSearch()
    }

    func moveFields(from offsets: IndexSet, to destination: Int) {
        var fields = fieldDefinitions()
        fields.move(fromOffsets: offsets, toOffset: destination)
        for (order, field) in fields.enumerated() { field.order = order }
        save()
    }

    func value(of field: FieldDefinition, for item: Item) -> String {
        CustomField.decode(item.customFields)[field.uuid] ?? ""
    }

    func setValue(_ value: String, of field: FieldDefinition, for items: [Item]) {
        for item in items {
            var values = CustomField.decode(item.customFields)
            values[field.uuid] = value
            let encoded = CustomField.encode(values)
            guard encoded != item.customFields else { continue }
            item.customFields = encoded
            item.modifiedAt = .now
            reindex(item)
        }
        save()
    }

    // MARK: - Reading queue

    func setReadLater(_ items: [Item], _ queued: Bool) {
        for item in items where (item.readLaterAt != nil) != queued {
            item.readLaterAt = queued ? .now : nil
        }
        save()
        revision += 1
    }

    /// How far through an item you are, and where to pick up: saved only
    /// when it's moved on by a percent or more.
    func setReadingProgress(_ item: Item, _ fraction: Double, position: String? = nil) {
        guard isAlive(item) else { return }
        let rounded = (min(max(fraction, 0), 1) * 100).rounded() / 100
        var changed = false
        if let position, item.readingPosition != position {
            item.readingPosition = position
            changed = true
        }
        if abs(item.readingProgress - rounded) >= 0.01 {
            item.readingProgress = rounded
            changed = true
        }
        if changed { save() }
    }
}
