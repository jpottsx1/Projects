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

    init(name: String, query: String) {
        self.name = name
        self.query = query
    }
}
