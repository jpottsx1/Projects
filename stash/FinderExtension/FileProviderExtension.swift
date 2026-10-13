import FileProvider
import StashCore
import UniformTypeIdentifiers

/// Stash in the Finder sidebar, Files, and Open and Save dialogs. Like the
/// share extension it never opens the library: it serves the folders and
/// files the app publishes (`FinderShare`), and leaves the changes made here
/// as requests for the app to carry out.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let share: FinderShare?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        share = FinderShare.forAppGroup()
        super.init()
    }

    func invalidate() {}

    private var snapshot: FinderSnapshot { share?.snapshot() ?? FinderSnapshot(version: 0, entries: []) }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FinderItem.root, nil)
        } else if let entry = snapshot.entry(identifier.rawValue) {
            completionHandler(FinderItem(entry), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let share, let entry = snapshot.entry(itemIdentifier.rawValue), let path = entry.contentPath else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        do {
            // The system takes the file it's given, so hand it a copy.
            let folder = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
            let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension((entry.name as NSString).pathExtension)
            try FileManager.default.copyItem(at: share.contentURL(path), to: copy)
            completionHandler(copy, FinderItem(entry), nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let parent = Self.entryID(itemTemplate.parentItemIdentifier)
        let isFolder = itemTemplate.contentType == .folder
        let request = FinderRequest(kind: isFolder ? .newFolder : .newFile, name: itemTemplate.filename, parent: parent,
                                    fileName: isFolder || url == nil ? nil : itemTemplate.filename)
        do {
            try share?.add(request, file: isFolder ? nil : url)
            FinderSignal.post()
            // Stands in until the app has made it and published it again.
            let now = Date()
            let placeholder = FinderEntry(id: "pending-" + request.id.uuidString, parent: parent, name: itemTemplate.filename,
                                          isFolder: isFolder, size: itemTemplate.documentSize??.intValue ?? 0,
                                          created: now, modified: now)
            completionHandler(FinderItem(placeholder), [], false, nil)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let id = item.itemIdentifier.rawValue
        guard let share, var entry = snapshot.entry(id) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        do {
            if changedFields.contains(.filename) {
                try share.add(FinderRequest(kind: .rename, entryID: id, name: item.filename))
                entry.name = item.filename
            }
            if changedFields.contains(.parentItemIdentifier) {
                let parent = Self.entryID(item.parentItemIdentifier)
                try share.add(FinderRequest(kind: .move, entryID: id, parent: parent))
                entry.parent = parent
            }
            if changedFields.contains(.contents), let newContents {
                try share.add(FinderRequest(kind: .replaceContents, entryID: id, fileName: entry.name), file: newContents)
                entry.modified = Date()
            }
            FinderSignal.post()
            completionHandler(FinderItem(entry), [], false, nil)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        do {
            // The app moves items to its Trash, and deletes categories.
            try share?.add(FinderRequest(kind: .delete, entryID: identifier.rawValue))
            FinderSignal.post()
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        return FinderEnumerator(container: containerItemIdentifier, share: share)
    }

    /// The root is "root" in the snapshot.
    static func entryID(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? FinderEntry.rootID : identifier.rawValue
    }
}

/// One folder or file, as the system sees it.
final class FinderItem: NSObject, NSFileProviderItem {
    let entry: FinderEntry

    init(_ entry: FinderEntry) {
        self.entry = entry
    }

    static let root = FinderItem(FinderEntry(id: FinderEntry.rootID, parent: FinderEntry.rootID, name: "Stash", isFolder: true,
                                             created: .distantPast, modified: .distantPast))

    var itemIdentifier: NSFileProviderItemIdentifier {
        entry.id == FinderEntry.rootID ? .rootContainer : NSFileProviderItemIdentifier(entry.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        entry.parent == FinderEntry.rootID ? .rootContainer : NSFileProviderItemIdentifier(entry.parent)
    }

    var filename: String { entry.name }

    var contentType: UTType {
        entry.isFolder ? .folder : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if entry.id == FinderEntry.rootID { return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating] }
        if entry.isFolder {
            return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }

    var itemVersion: NSFileProviderItemVersion {
        let content = Data("\(entry.modified.timeIntervalSinceReferenceDate)-\(entry.size)".utf8)
        let metadata = Data("\(entry.name)/\(entry.parent)".utf8)
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
    }

    var documentSize: NSNumber? { entry.isFolder ? nil : NSNumber(value: entry.size) }
    var creationDate: Date? { entry.created }
    var contentModificationDate: Date? { entry.modified }
}

/// A folder's contents, or (for the working set) everything. Changes
/// aren't tracked one by one: when the app has published a new snapshot,
/// the anchor has moved on and the system is asked to look again.
final class FinderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let share: FinderShare?

    init(container: NSFileProviderItemIdentifier, share: FinderShare?) {
        self.container = container
        self.share = share
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let snapshot = share?.snapshot() ?? FinderSnapshot(version: 0, entries: [])
        let entries = container == .workingSet
            ? snapshot.entries
            : snapshot.children(of: FileProviderExtension.entryID(container))
        observer.didEnumerate(entries.map(FinderItem.init))
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let current = Self.anchor(share?.snapshot().version ?? 0)
        if anchor == current {
            observer.finishEnumeratingChanges(upTo: current, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor(share?.snapshot().version ?? 0))
    }

    private static func anchor(_ version: Int) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(version).utf8))
    }
}
