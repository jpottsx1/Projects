import Foundation
import SwiftData
import StashCore

/// Any number per item.
@Model
final class Tag {
    /// Decides which copy survives when two devices made the same tag
    /// before syncing (see `Library.mergeDuplicates`).
    var uuid: UUID = UUID()
    var name: String = ""
    var items: [Item]? = []

    init(name: String) {
        self.name = TagName.clean(name)
    }

    var key: String { TagName.key(name) }
}
