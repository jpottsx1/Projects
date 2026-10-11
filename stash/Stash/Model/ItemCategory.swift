import Foundation
import SwiftData

/// One per item, and they nest: "Work" can hold "Clients" and "Admin".
/// Showing a category shows everything in the categories inside it too.
@Model
final class ItemCategory {
    /// Decides which copy survives when two devices made the same category
    /// before syncing (see `Library.mergeDuplicates`).
    var uuid: UUID = UUID()
    var name: String = ""
    var parent: ItemCategory?
    @Relationship(deleteRule: .cascade, inverse: \ItemCategory.parent) var children: [ItemCategory]? = []
    @Relationship(deleteRule: .nullify, inverse: \Item.category) var items: [Item]? = []

    init(name: String, parent: ItemCategory? = nil) {
        self.name = name
        self.parent = parent
    }

    /// Nil rather than empty when there are none, which is what OutlineGroup
    /// needs to draw a row without a disclosure triangle.
    var subcategories: [ItemCategory]? {
        let sorted = (children ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sorted.isEmpty ? nil : sorted
    }

    /// "Work › Clients"
    var path: String {
        var names = [name]
        var next = parent
        while let category = next {
            names.insert(category.name, at: 0)
            next = category.parent
        }
        return names.joined(separator: " › ")
    }

    /// Whether `other` is this category or one somewhere inside it.
    func contains(_ other: ItemCategory?) -> Bool {
        var next = other
        while let category = next {
            if category == self { return true }
            next = category.parent
        }
        return false
    }

    /// This category and every one inside it, depth first.
    var flattened: [ItemCategory] {
        [self] + (subcategories ?? []).flatMap(\.flattened)
    }
}
