import FileProvider
import Foundation
import SwiftData
import StashCore
import UniformTypeIdentifiers

/// Stash's place in the Finder sidebar and in Files. The File Provider
/// extension can't open the library, so the app publishes its categories as
/// folders and its items as files (documents as themselves, notes as
/// Markdown, links as .webloc) into the App Group, and carries out the
/// changes made there. Only for the main library, and only with sharing on.
extension Library {
    private static let finderDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("Stash"), displayName: "Stash")

    func startFinder() {
        guard finder != nil else { return }
        NSFileProviderManager.add(Self.finderDomain) { error in
            if let error { Library.performanceLog.error("Couldn't add Stash to the Finder: \(error.localizedDescription)") }
        }
        FinderSignal.startListening()
        finderObserver = NotificationCenter.default.addObserver(
            forName: .stashFinderRequestsArrived, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.processFinderRequests() }
        }
        processFinderRequests()
        publishToFinder()
    }

    func scheduleFinderUpdate() {
        guard finder != nil else { return }
        pendingFinderUpdate?.cancel()
        pendingFinderUpdate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.publishToFinder()
        }
    }

    // MARK: - Publishing

    /// Writes the folders and files out, and tells the Finder if anything changed.
    func publishToFinder() {
        guard let finder,
              let items = try? context.fetch(FetchDescriptor<Item>()),
              let categories = try? context.fetch(FetchDescriptor<ItemCategory>()) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: finder.contentFolder, withIntermediateDirectories: true)

        var entries = categories.sorted(by: ItemCategory.inOrder).map { category in
            FinderEntry(id: "c-" + category.uuid.uuidString, parent: Self.finderParent(category.parent),
                        name: FinderSnapshot.fileName(category.name, ext: ""), isFolder: true,
                        created: .distantPast, modified: .distantPast)
        }
        var kept: Set<String> = []
        // Nothing locked, trashed or in a template; nor files that are
        // already in the Finder in an indexed folder.
        let shown = items.filter { !$0.isTrashed && !$0.isTemplate && !$0.isLocked && !$0.isSealed && $0.indexedFolder == nil }
        for item in shown.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            guard let (name, contentPath) = publishContents(of: item, to: finder) else { continue }
            kept.insert(contentPath)
            let size = (try? finder.contentURL(contentPath).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            entries.append(FinderEntry(id: "i-" + item.uuid.uuidString, parent: Self.finderParent(item.category), name: name,
                                       isFolder: false, size: size, created: item.createdAt, modified: item.modifiedAt,
                                       contentPath: contentPath))
        }
        // Contents of things no longer shown.
        for url in (try? fileManager.contentsOfDirectory(at: finder.contentFolder, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        entries = FinderSnapshot.uniquelyNamed(entries)
        let old = finder.snapshot()
        guard entries != old.entries else { return }
        try? finder.write(FinderSnapshot(version: old.version + 1, entries: entries))
        NSFileProviderManager(for: Self.finderDomain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    private static func finderParent(_ category: ItemCategory?) -> String {
        category.map { "c-" + $0.uuid.uuidString } ?? FinderEntry.rootID
    }

    /// The item's file in the Finder: its name there, and its contents'
    /// name in the Content folder. Only written again when it's changed.
    private func publishContents(of item: Item, to finder: FinderShare) -> (String, String)? {
        let fileManager = FileManager.default
        switch item.kind {
        case .document:
            guard let source = localFile(for: item) else { return nil }
            let ext = source.pathExtension
            let contentPath = item.uuid.uuidString + (ext.isEmpty ? "" : "." + ext)
            let destination = finder.contentURL(contentPath)
            // A hard link where it can be (the same file, no extra space),
            // a copy otherwise.
            if !Self.isSameFile(source, destination), Self.modificationDate(destination) != Self.modificationDate(source) {
                try? fileManager.removeItem(at: destination)
                if (try? fileManager.linkItem(at: source, to: destination)) == nil {
                    try? fileManager.copyItem(at: source, to: destination)
                }
            }
            return (FinderSnapshot.fileName(item.displayTitle, ext: ext), contentPath)
        case .note:
            let contentPath = item.uuid.uuidString + ".md"
            writeIfChanged(Data(item.body.utf8), to: finder.contentURL(contentPath), modified: item.modifiedAt)
            return (FinderSnapshot.fileName(item.displayTitle, ext: "md"), contentPath)
        case .link:
            guard let url = item.urlString else { return nil }
            let contentPath = item.uuid.uuidString + ".webloc"
            writeIfChanged(FinderSnapshot.webloc(for: url), to: finder.contentURL(contentPath), modified: item.modifiedAt)
            return (FinderSnapshot.fileName(item.displayTitle, ext: "webloc"), contentPath)
        }
    }

    private func writeIfChanged(_ data: Data, to url: URL, modified: Date) {
        if let date = Self.modificationDate(url), date >= modified { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    // MARK: - Changes made in the Finder

    /// Carries out what's been done in the Finder: at launch, when Stash
    /// comes to the front, and when the extension signals.
    func processFinderRequests() {
        guard let finder else { return }
        let waiting = finder.pending()
        guard !waiting.isEmpty else { return }
        let snapshot = finder.snapshot()
        for pending in waiting {
            carryOut(pending, snapshot: snapshot)
            finder.remove(pending)
        }
        save()
        publishCategories()
        publishToFinder()
    }

    private func carryOut(_ pending: FinderShare.Pending, snapshot: FinderSnapshot) {
        let request = pending.request
        let entry = request.entryID.flatMap(snapshot.entry)
        let item = entry.flatMap { $0.isCategory ? nil : $0.uuid }.flatMap { items(withIDs: [$0]).first }
        let category = entry.flatMap { $0.isCategory ? $0.uuid : nil }.flatMap(finderCategory)
        let parent = request.parent.flatMap { $0 == FinderEntry.rootID ? nil : UUID(uuidString: String($0.dropFirst(2))) }
            .flatMap(finderCategory)

        switch request.kind {
        case .rename:
            guard let name = request.name else { return }
            if let category {
                rename(category, to: name)
            } else if let item {
                let oldTitle = item.title
                item.title = (name as NSString).deletingPathExtension
                item.modifiedAt = .now
                rename(item, from: oldTitle)
                didEdit(item)
            }
        case .move:
            if let item {
                file([item], in: parent)
            } else if let category, parent.map({ !category.contains($0) }) ?? true {
                category.parent = parent
            }
        case .delete:
            if let item { moveToTrash([item]) } else if let category { delete(category) }
        case .newFolder:
            newCategory(named: request.name ?? "Untitled", in: parent)
        case .newFile:
            guard let file = pending.file else { return }
            addFromFinder(file, named: request.name ?? file.lastPathComponent, in: parent)
        case .replaceContents:
            guard let item, let file = pending.file else { return }
            replaceContents(of: item, with: file)
        }
    }

    private func finderCategory(_ id: UUID) -> ItemCategory? {
        try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == id })).first
    }

    /// A file saved or dropped into Stash in the Finder.
    private func addFromFinder(_ file: URL, named name: String, in category: ItemCategory?) {
        let title = (name as NSString).deletingPathExtension
        let ext = file.pathExtension.lowercased()
        let item: Item
        if ext == "webloc", let url = Self.weblocURL(file) {
            item = addLink(url)
            if !title.isEmpty { item.title = title }
        } else if ["md", "markdown", "txt"].contains(ext), let text = try? String(contentsOf: file, encoding: .utf8) {
            item = newNote(titled: title, text: text)
        } else {
            item = Item(kind: .document, title: title)
            guard let path = try? files.importFile(at: file, for: item.uuid) else { return }
            item.storedFilePath = path
            item.contentTypeIdentifier = UTType(filenameExtension: file.pathExtension)?.identifier
            item.fileData = syncableContents(of: item)
            insert(item, select: false)
            arrived(item)
            Task {
                await fillContentHash(of: item)
                await fillThumbnail(of: item)
                await extractText(from: item)
            }
        }
        item.category = category
        item.inInbox = category == nil
        didChangeCategory(of: item)
    }

    /// A file edited in the Finder (or saved over in another app).
    private func replaceContents(of item: Item, with file: URL) {
        switch item.kind {
        case .note:
            guard let text = try? String(contentsOf: file, encoding: .utf8), text != item.body else { return }
            item.body = text
            item.modifiedAt = .now
            didEdit(item)
        case .link:
            guard let url = Self.weblocURL(file) else { return }
            item.urlString = url.absoluteString
            item.modifiedAt = .now
            reindex(item)
        case .document:
            guard let path = item.storedFilePath, !item.isSealed, let data = try? Data(contentsOf: file) else { return }
            try? files.write(data, to: path)
            Task { await fileDidChange(item) }
        }
    }

    private static func weblocURL(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String else { return nil }
        return URL(string: string)
    }
}
