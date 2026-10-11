import Foundation
import SwiftData
import StashCore

/// Any number per item.
@Model
final class Tag {
    var name: String = ""
    var items: [Item]? = []

    init(name: String) {
        self.name = TagName.clean(name)
    }

    var key: String { TagName.key(name) }
}
