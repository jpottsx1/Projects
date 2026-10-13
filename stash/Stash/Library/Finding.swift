import Foundation
import SwiftData
import StashCore

/// Keep It's ways of finding things: the tag filter, Recents and Unfiled,
/// and a category for new things to arrive in instead of the Inbox.
extension Library {
    // MARK: - Tag filter

    /// The tags to offer next: those on the items shown, apart from the
    /// ones chosen, most used first.
    func relatedTags(among items: [Item]) -> [TagFilter.Related] {
        TagFilter.related(items.map { ($0.tags ?? []).map(\.name) }, chosen: tagFilter)
    }

    func toggleTagFilter(_ name: String) {
        if let index = tagFilter.firstIndex(where: { TagName.key($0) == TagName.key(name) }) {
            tagFilter.remove(at: index)
        } else {
            tagFilter.append(name)
        }
    }

    // MARK: - Import destination

    /// The category new things arrive in instead of the Inbox, if one is set.
    /// Two devices may each have set one before syncing; the lowest uuid wins.
    var importDestination: ItemCategory? {
        let chosen = (try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.isImportDestination }))) ?? []
        return chosen.min { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    func setImportDestination(_ category: ItemCategory?) {
        for old in (try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.isImportDestination }))) ?? [] {
            old.isImportDestination = false
        }
        category?.isImportDestination = true
        save()
    }

    /// Something that has come in with no category: to the import
    /// destination if there is one, otherwise to the Inbox.
    func fileArrival(_ item: Item) {
        guard item.category == nil else { return }
        if let destination = importDestination {
            item.category = destination
            item.inInbox = false
        } else {
            item.inInbox = true
        }
    }

    // MARK: - Sizes

    /// Notes documents' sizes, for those that don't have one yet.
    func fillFileSizes(_ items: [Item]) {
        var changed = false
        for item in items where item.kind == .document && item.fileSize == 0 && item.indexedFolder == nil {
            guard let path = item.storedFilePath, files.exists(path),
                  let size = try? files.url(for: path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
            item.fileSize = size
            changed = true
        }
        if changed { save() }
    }
}

extension Item {
    /// What `size:` compares: a document's file, or the text of anything else.
    var searchableSize: Int64 {
        if kind == .document { return Int64(fileSize > 0 ? fileSize : indexedFileSize) }
        return Int64(body.utf8.count)
    }
}
