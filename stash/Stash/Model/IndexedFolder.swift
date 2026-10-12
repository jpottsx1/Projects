import Foundation
import SwiftData

/// A folder in Finder (or Files) whose documents are shown in Stash while
/// they stay where they are, as DEVONthink's indexing does. Changes made
/// there -- files added, edited, moved, deleted -- are followed.
///
/// The folder belongs to the device that added it: another device sees its
/// items, but not their files.
@Model
final class IndexedFolder {
    var uuid: UUID = UUID()
    var name: String = ""
    /// Where it is, for showing; the bookmark is what finds it.
    var path: String = ""
    /// A security-scoped bookmark, which only works on the device that made it.
    var bookmark: Data?
    /// The device it's on.
    var deviceName: String = ""
    var addedAt: Date = Date()
    var lastScannedAt: Date?
    /// The category its files are filed in, with one inside for each folder.
    var categoryID: UUID?
    /// Files deleted from Stash on purpose, which shouldn't come back the
    /// next time the folder is looked at. One path per line.
    var ignoredPaths: String = ""
    @Relationship(deleteRule: .nullify, inverse: \Item.indexedFolder) var items: [Item]? = []

    init(name: String, path: String, bookmark: Data?, deviceName: String) {
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.deviceName = deviceName
    }

    var ignored: Set<String> { Set(ignoredPaths.split(separator: "\n").map(String.init)) }

    func ignore(_ path: String) {
        guard !ignored.contains(path) else { return }
        ignoredPaths += (ignoredPaths.isEmpty ? "" : "\n") + path
    }
}
