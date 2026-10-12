import Foundation
import SwiftData

/// How a note read before it was edited. One is kept when an editing
/// session ends with the note changed, and every ten minutes during a
/// long one; the newest fifty are kept (see `Library.keepVersion`).
@Model
final class NoteVersion {
    var uuid: UUID = UUID()
    var item: Item?
    var title: String = ""
    var body: String = ""
    /// When the note last read like this.
    var savedAt: Date = Date()

    init(title: String, body: String, savedAt: Date) {
        self.title = title
        self.body = body
        self.savedAt = savedAt
    }
}
