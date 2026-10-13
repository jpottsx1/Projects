import Foundation
import SwiftData

/// A list you put items in by hand, in your own order, as Keep It's lists
/// and DEVONthink's replicants: an item can be in any number of lists as
/// well as its one category.
@Model
final class ItemList {
    var uuid: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    /// The items' order, as their uuids, one per line. Items not in it
    /// (added on another device, say) come after, oldest first.
    var orderIDs: String = ""
    var items: [Item]? = []
    /// Smart filters that search only in this list, shown under it.
    @Relationship(deleteRule: .nullify, inverse: \SmartFilter.list) var smartFilters: [SmartFilter]? = []

    init(name: String) {
        self.name = name
    }

    var order: [UUID] {
        get { orderIDs.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } }
        set { orderIDs = newValue.map(\.uuidString).joined(separator: "\n") }
    }

    /// Its items in their order.
    var orderedItems: [Item] {
        let all = items ?? []
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return all.sorted { a, b in
            switch (position[a.uuid], position[b.uuid]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.createdAt, a.uuid.uuidString) < (b.createdAt, b.uuid.uuidString)
            }
        }
    }
}
