import Foundation
import SwiftData
import StashCore

/// Notion's database fields on Stash's own: relations to other items,
/// rollups across them, and formulas over an item's fields.
extension Library {
    /// A field's value as stored or worked out, and the kind it reads as.
    /// Relations read as the related items' titles.
    func resolvedValue(of field: FieldDefinition, for item: Item, fields: [FieldDefinition]? = nil, depth: Int = 0) -> (String, CustomField.Kind) {
        // Fields that refer to each other in a circle stop here.
        guard depth < 6 else { return ("", .text) }
        let stored = value(of: field, for: item)
        switch field.kind {
        case .relation:
            return (relatedItems(stored).map(\.displayTitle).joined(separator: ", "), .relation)
        case .rollup:
            let config = field.fieldConfig
            let all = fields ?? fieldDefinitions()
            guard let relationID = config.relation, let relation = all.first(where: { $0.uuid == relationID }) else { return ("", .text) }
            let related = relatedItems(value(of: relation, for: item))
            let target = config.target.flatMap { id in all.first { $0.uuid == id } }
            let values: [String]
            let kind: CustomField.Kind
            if let target {
                let resolved = related.map { resolvedValue(of: target, for: $0, fields: all, depth: depth + 1) }
                values = resolved.map(\.0)
                kind = resolved.first?.1 ?? target.kind
            } else {
                values = related.map(\.displayTitle)
                kind = .text
            }
            return Rollup.compute(values, kind: kind, function: config.function)
        case .formula:
            let all = fields ?? fieldDefinitions()
            let result = try? Formula.evaluate(field.fieldConfig.formula, field: { name in
                self.formulaValue(named: name, for: item, fields: all, depth: depth)
            })
            return result?.stored ?? ("", .text)
        default:
            return (stored, field.kind)
        }
    }

    /// How a field's value reads, in a list, column or the side panel.
    func displayValue(of field: FieldDefinition, for item: Item) -> String {
        let (value, kind) = resolvedValue(of: field, for: item)
        return kind == .relation ? value : CustomField.display(value, kind: kind)
    }

    /// Why a formula can't be worked out for this item, if it can't.
    func formulaError(_ field: FieldDefinition, for item: Item) -> String? {
        let all = fieldDefinitions()
        do {
            _ = try Formula.evaluate(field.fieldConfig.formula, field: { name in
                self.formulaValue(named: name, for: item, fields: all, depth: 0)
            })
            return nil
        } catch {
            return (error as? Formula.Failure)?.message ?? error.localizedDescription
        }
    }

    /// A field, or the item's own title, created or modified date, by name, as a formula sees it.
    private func formulaValue(named name: String, for item: Item, fields: [FieldDefinition], depth: Int) -> Formula.Value? {
        let key = name.lowercased()
        switch key {
        case "title", "name": return .text(item.displayTitle)
        case "created": return .date(item.createdAt)
        case "modified": return .date(item.modifiedAt)
        case "rating": return .number(Double(item.rating))
        default: break
        }
        guard let field = fields.first(where: { $0.name.lowercased() == key }) else { return nil }
        let (value, kind) = resolvedValue(of: field, for: item, fields: fields, depth: depth + 1)
        return Formula.value(value, kind: kind)
    }

    func relatedItems(_ stored: String) -> [Item] {
        let ids = CustomField.relatedIDs(stored)
        guard !ids.isEmpty else { return [] }
        return items(withIDs: ids).filter { !$0.isTrashed }
    }

    func relate(_ item: Item, to other: Item, through field: FieldDefinition) {
        guard field.kind == .relation, item != other else { return }
        let ids = CustomField.relatedIDs(value(of: field, for: item))
        setValue(CustomField.storedRelation(ids + [other.uuid]), of: field, for: [item])
    }

    func unrelate(_ item: Item, from other: Item, through field: FieldDefinition) {
        let ids = CustomField.relatedIDs(value(of: field, for: item)).filter { $0 != other.uuid }
        setValue(CustomField.storedRelation(ids), of: field, for: [item])
    }

    /// Items whose relation fields lead here, with the field: the other side of a relation.
    func itemsRelating(to item: Item) -> [(Item, FieldDefinition)] {
        let relations = fieldDefinitions().filter { $0.kind == .relation }
        guard !relations.isEmpty else { return [] }
        let id = item.uuid.uuidString
        let candidates = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.customFields.contains(id) }))) ?? []
        return candidates.filter { !$0.isTrashed && $0 != item }.flatMap { other in
            relations.filter { CustomField.relatedIDs(value(of: $0, for: other)).contains(item.uuid) }.map { (other, $0) }
        }
    }

    func setFieldConfig(_ config: FieldConfig, of field: FieldDefinition) {
        field.fieldConfig = config
        save()
        revision += 1
        runSearch()
    }

    // MARK: - Calendar view

    /// What the calendar view places items by.
    enum CalendarDate: Hashable {
        case created, modified, reminder
        case field(UUID)
    }

    func calendarDate(of item: Item, by source: CalendarDate, fields: [FieldDefinition]) -> Date? {
        switch source {
        case .created: return item.createdAt
        case .modified: return item.modifiedAt
        case .reminder: return item.remindAt
        case .field(let id):
            guard let field = fields.first(where: { $0.uuid == id }) else { return nil }
            let (value, kind) = resolvedValue(of: field, for: item, fields: fields)
            return kind == .date ? CustomField.date(from: value) : nil
        }
    }

    /// Dropped on another day: the date moves there (only dates that can be set).
    func moveDate(of item: Item, by source: CalendarDate, to day: Date) {
        switch source {
        case .reminder:
            let time = item.remindAt.map { Calendar.current.dateComponents([.hour, .minute], from: $0) } ?? DateComponents(hour: 9, minute: 0)
            let date = Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
            setReminder([item], at: date)
        case .field(let id):
            guard let field = fieldDefinitions().first(where: { $0.uuid == id }), field.kind == .date else { return }
            setValue(CustomField.storedDate(day), of: field, for: [item])
        case .created, .modified:
            break
        }
    }
}
