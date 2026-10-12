import Foundation
import SwiftData

/// A picture pasted or dropped into a note, referred to from its text as
/// `![](attachment:name)`. The data syncs; each device writes it out
/// beside the note's other files to show it.
@Model
final class NoteAttachment {
    var uuid: UUID = UUID()
    var item: Item?
    /// Unique within the note: what `attachment:` names.
    var fileName: String = ""
    @Attribute(.externalStorage) var data: Data?
    var createdAt: Date = Date()

    init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}
