import Foundation
import SwiftData

/// A saved search, shown in the sidebar. It keeps the words typed, not
/// the results, so it always shows what matches now (see `SearchQuery`
/// for what can be typed).
@Model
final class SmartFilter {
    var uuid: UUID = UUID()
    var name: String = ""
    var query: String = ""
    var createdAt: Date = Date()
    /// Its place in the sidebar when moved by hand; equal ones go by name.
    var order: Int = 0
    /// Where it searches: one category (and those inside it), or one
    /// list; the whole library when neither.
    var category: ItemCategory?
    var list: ItemList?

    init(name: String, query: String) {
        self.name = name
        self.query = query
    }

    var scope: SmartFilterScope {
        get {
            if let category { return .category(category) }
            if let list { return .list(list) }
            return .library
        }
        set {
            switch newValue {
            case .library: category = nil; list = nil
            case .category(let chosen): category = chosen; list = nil
            case .list(let chosen): list = chosen; category = nil
            }
        }
    }
}

/// Where a smart filter searches.
enum SmartFilterScope: Hashable {
    case library
    case category(ItemCategory)
    case list(ItemList)
}
