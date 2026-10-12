import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore
#if os(macOS)
import AppKit
import CoreServices
#else
import UIKit
#endif

/// Indexed folders: documents shown in Stash while their files stay where
/// they are, kept in step as files are added, changed, moved and deleted
/// there. Each folder gets a category, with one inside it for each folder
/// inside it.
extension Library {
    func indexedFolders() -> [IndexedFolder] {
        (try? context.fetch(FetchDescriptor<IndexedFolder>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "this Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// Starts indexing a folder chosen in the open panel.
    func index(folder url: URL) async {
        _ = url.startAccessingSecurityScopedResource()
        let path = url.path
        if let existing = indexedFolders().first(where: { $0.path == path && folderURL(for: $0) != nil }) {
            await rescan(existing)
            return
        }
        let bookmark: Data?
        do {
            bookmark = try Self.bookmark(for: url)
        } catch {
            importError = "Stash can’t keep track of “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        let folder = IndexedFolder(name: url.lastPathComponent, path: path, bookmark: bookmark, deviceName: Self.deviceName)
        context.insert(folder)
        let category = newCategory(named: folder.name)
        folder.categoryID = category?.uuid
        save()
        indexedFolderURLs[folder.uuid] = url
        watch(folder, at: url)
        if let category { sidebar = .category(category) }
        await rescan(folder)
    }

    private static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Where the folder is on this device, opened for reading; nil on
    /// other devices, or once it's been deleted.
    func folderURL(for folder: IndexedFolder) -> URL? {
        if let url = indexedFolderURLs[folder.uuid] { return url }
        guard let bookmark = folder.bookmark else { return nil }
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        // Kept open for as long as Stash is.
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if isStale, let fresh = try? Self.bookmark(for: url) {
            folder.bookmark = fresh
            folder.path = url.path
            save()
        }
        indexedFolderURLs[folder.uuid] = url
        return url
    }

    /// An indexed document's file, where it is in its folder.
    func indexedFile(for item: Item) -> URL? {
        guard let folder = item.indexedFolder, let path = item.indexedPath, let root = folderURL(for: folder) else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the folder is on this device.
    func isHere(_ folder: IndexedFolder) -> Bool {
        folderURL(for: folder) != nil
    }

    /// At launch: opens the folders on this device, watches them, and
    /// catches up with what changed while Stash was closed.
    func openIndexedFolders() {
        for folder in indexedFolders() {
            guard let url = folderURL(for: folder) else { continue }
            watch(folder, at: url)
        }
        Task { await rescanIndexedFolders() }
    }

    func rescanIndexedFolders() async {
        for folder in indexedFolders() where isHere(folder) {
            await rescan(folder)
        }
    }

    private func watch(_ folder: IndexedFolder, at url: URL) {
        #if os(macOS)
        guard folderWatchers[folder.uuid] == nil else { return }
        let id = folder.uuid
        folderWatchers[id] = FolderWatcher(url: url) { [weak self] in
            guard let self, let folder = self.indexedFolders().first(where: { $0.uuid == id }) else { return }
            Task { await self.rescan(folder) }
        }
        #endif
    }

    // MARK: - Keeping in step

    /// Reads the folder again and brings the library into line with it.
    func rescan(_ folder: IndexedFolder) async {
        guard let root = folderURL(for: folder) else { return }
        let id = folder.uuid
        guard !scanningFolders.contains(id) else {
            pendingRescans.insert(id)
            return
        }
        scanningFolders.insert(id)
        let onDisk = await Task.detached(priority: .utility) { Self.files(in: root) }.value
        defer {
            scanningFolders.remove(id)
            if pendingRescans.remove(id) != nil { Task { await rescan(folder) } }
        }
        guard folder.modelContext != nil, !folder.isDeleted else { return }

        let ignored = folder.ignored
        let items = folder.items ?? []
        let byID = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let known = items.compactMap { item -> FolderIndex.Known? in
            guard let path = item.indexedPath else { return nil }
            return FolderIndex.Known(id: item.uuid, file: .init(path: path, size: item.indexedFileSize,
                                                                 modified: item.indexedFileDate ?? .distantPast))
        }
        let changes = FolderIndex.changes(onDisk: onDisk.filter { !ignored.contains($0.path) }, known: known)
        guard !changes.isEmpty else {
            folder.lastScannedAt = .now
            return
        }

        var toRead: [Item] = []
        for file in changes.added {
            toRead.append(addIndexed(file, in: folder))
        }
        for (itemID, file) in changes.changed {
            guard let item = byID[itemID] else { continue }
            item.indexedFileSize = file.size
            item.indexedFileDate = file.modified
            Task { await fileDidChange(item) }
        }
        for (itemID, file) in changes.moved {
            guard let item = byID[itemID], let oldPath = item.indexedPath else { continue }
            // Its category and title follow the file, unless they've been changed by hand.
            if item.category == category(for: FolderIndex.folders(of: oldPath), in: folder, making: false) {
                item.category = category(for: FolderIndex.folders(of: file.path), in: folder, making: true)
            }
            if item.title == Self.title(of: oldPath) { item.title = Self.title(of: file.path) }
            item.indexedPath = file.path
            reindex(item)
        }
        // Gone from the folder: to the Trash, where they can be seen to have gone.
        let removed = changes.removed.compactMap { byID[$0] }
        for item in removed { item.indexedPath = nil }
        moveToTrash(removed.filter { !$0.isTrashed })

        folder.lastScannedAt = .now
        save()
        revision += 1
        guard !toRead.isEmpty else { return }
        // One at a time: a folder can hold thousands of files.
        Task {
            for item in toRead where isAlive(item) {
                await fillContentHash(of: item)
                await fillThumbnail(of: item)
                await extractText(from: item)
            }
        }
    }

    private func addIndexed(_ file: FolderIndex.File, in folder: IndexedFolder) -> Item {
        let item = Item(kind: .document, title: Self.title(of: file.path))
        item.indexedPath = file.path
        item.indexedFileSize = file.size
        item.indexedFileDate = file.modified
        item.contentTypeIdentifier = UTType(filenameExtension: (file.path as NSString).pathExtension)?.identifier
        item.createdAt = file.modified
        item.modifiedAt = file.modified
        context.insert(item)
        item.indexedFolder = folder
        item.category = category(for: FolderIndex.folders(of: file.path), in: folder, making: true)
        reindex(item)
        return item
    }

    private static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The category for a folder inside the indexed one, made if it's
    /// wanted and isn't there.
    private func category(for folders: [String], in folder: IndexedFolder, making: Bool) -> ItemCategory? {
        var current: ItemCategory?
        if let id = folder.categoryID {
            current = (try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == id })))?.first
        }
        if current == nil {
            guard making, let made = newCategory(named: folder.name) else { return nil }
            folder.categoryID = made.uuid
            current = made
        }
        for name in folders {
            guard let parent = current else { return nil }
            if let child = (parent.children ?? []).filter({ $0.name == name }).min(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
                current = child
            } else if making {
                current = newCategory(named: name, in: parent)
            } else {
                return nil
            }
        }
        return current
    }

    /// The files in a folder and the folders inside it, skipping hidden ones.
    nonisolated static func files(in root: URL) -> [FolderIndex.File] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var files: [FolderIndex.File] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true { continue }
            guard !FolderIndex.isIgnored(url.lastPathComponent) else { continue }
            let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > base.count, Array(components.prefix(base.count)) == base else { continue }
            files.append(FolderIndex.File(path: components.dropFirst(base.count).joined(separator: "/"),
                                          size: values.fileSize ?? values.totalFileSize ?? 0,
                                          modified: values.contentModificationDate ?? .distantPast))
            if files.count >= 20_000 { break }
        }
        return files
    }

    // MARK: - Managing

    /// Stops indexing a folder. Its items leave the library; its files stay
    /// where they are.
    func removeIndexedFolder(_ folder: IndexedFolder) {
        let items = folder.items ?? []
        deleteImmediately(items)
        folderWatchers[folder.uuid] = nil
        indexedFolderURLs[folder.uuid]?.stopAccessingSecurityScopedResource()
        indexedFolderURLs[folder.uuid] = nil
        context.delete(folder)
        save()
    }

    #if os(macOS)
    func showInFinder(_ item: Item) {
        guard let url = localFile(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}

#if os(macOS)
/// Hears about changes inside a folder, from FSEvents, a second after they
/// settle.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#else
/// On an iPhone or iPad folders are read again when Stash comes to the front.
final class FolderWatcher {}
#endif
