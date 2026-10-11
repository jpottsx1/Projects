import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// Exporting items -- or everything, as a backup -- to a ZIP file, and
/// restoring from one.
///
/// An export is readable without Stash: a folder per category, notes and
/// links as Markdown, documents as they were, saved pages as web archives.
/// Beside them, `Stash Backup.json` records everything else, so restoring
/// brings back ids, categories, tags, links between items, highlights and
/// smart filters exactly.
extension Library {
    struct ExportJob: Sendable {
        enum Source: Sendable {
            case data(Data)
            case file(URL)
        }

        struct Entry: Sendable {
            var path: String
            var source: Source
            var modified: Date
        }

        var entries: [Entry] = []
    }

    struct RestoreSummary {
        var added = 0
        /// Already in the library, so left as they are.
        var skipped = 0
    }

    enum BackupError: LocalizedError {
        case notABackup

        var errorDescription: String? {
            switch self {
            case .notABackup: "This ZIP file wasn’t exported from Stash."
            }
        }
    }

    /// Writes `items` -- or, with `everything`, the whole library including
    /// the Trash and smart filters -- to a ZIP file in a temporary folder,
    /// and returns it.
    func export(_ items: [Item], everything: Bool, named name: String) async throws -> URL {
        let job = try prepareExport(items, everything: everything)
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ExportNaming.safe(name) + ".zip")
        try await Task.detached(priority: .userInitiated) {
            let writer = try ZipWriter(url: url)
            for entry in job.entries {
                switch entry.source {
                case .data(let data): try writer.add(entry.path, data: data, modified: entry.modified)
                case .file(let file): try writer.add(entry.path, contentsOf: file, modified: entry.modified)
                }
            }
            try writer.finish()
        }.value
        return url
    }

    func exportEverything() async throws -> URL {
        let items = try context.fetch(FetchDescriptor<Item>())
        let date = Date.now.formatted(.iso8601.year().month().day())
        return try await export(items, everything: true, named: "Stash Backup \(date)")
    }

    private func prepareExport(_ items: [Item], everything: Bool) throws -> ExportJob {
        let allCategories = try context.fetch(FetchDescriptor<ItemCategory>())
        // A partial export only needs the categories its items are in.
        var used: Set<UUID> = []
        for item in items {
            var next = item.category
            while let category = next, used.insert(category.uuid).inserted { next = category.parent }
        }
        let categories = allCategories.filter { everything || used.contains($0.uuid) }

        var manifest = BackupManifest(
            exportedAt: .now,
            categories: categories.map { .init(id: $0.uuid, name: $0.name, parent: $0.parent?.uuid) })
        if everything {
            manifest.smartFilters = try context.fetch(FetchDescriptor<SmartFilter>())
                .map { .init(id: $0.uuid, name: $0.name, query: $0.query, createdAt: $0.createdAt) }
            manifest.rules = try context.fetch(FetchDescriptor<SmartRule>()).map {
                .init(id: $0.uuid, name: $0.name, query: $0.query, isEnabled: $0.isEnabled, createdAt: $0.createdAt,
                      category: $0.category?.uuid, tags: $0.tagsToAdd, label: $0.labelRaw, rating: $0.rating,
                      makesFavorite: $0.makesFavorite, marksRead: $0.marksRead, takesOutOfInbox: $0.takesOutOfInbox)
            }
        }

        var job = ExportJob()
        var taken: Set<String> = [BackupManifest.fileName.lowercased()]
        for item in items {
            var record = BackupManifest.ItemRecord(id: item.uuid, kind: item.kindRaw, title: item.title,
                                                   createdAt: item.createdAt, modifiedAt: item.modifiedAt)
            record.body = item.body
            record.summary = item.summary
            record.url = item.urlString
            record.isFavorite = item.isFavorite
            record.trashedAt = item.trashedAt
            record.isUnread = item.isUnread
            record.inInbox = item.inInbox
            record.label = item.labelRaw
            record.rating = item.rating
            record.category = item.category?.uuid
            record.tags = item.sortedTags.map(\.name)
            record.linksTo = (item.linksTo ?? []).map(\.uuid)
            record.contentType = item.contentTypeIdentifier
            record.contentHash = item.contentHash
            record.extractedText = item.extractedText
            record.readingPosition = item.readingPosition
            record.archivedAt = item.archivedAt
            record.highlights = item.sortedHighlights.map {
                .init(id: $0.uuid, text: $0.text, note: $0.note, color: $0.colorRaw, anchor: $0.anchorJSON,
                      position: $0.position, createdAt: $0.createdAt)
            }

            var folder = manifest.folder(for: item.category?.uuid)
            if item.isTrashed { folder = folder.isEmpty ? "Trash" : "Trash/" + folder }

            if item.kind == .document, let file = localFile(for: item) {
                let ext = file.pathExtension
                let path = ExportNaming.unique(item.displayTitle, ext: ext, in: folder, taken: &taken)
                record.file = path
                job.entries.append(.init(path: path, source: .file(file), modified: item.modifiedAt))
            }
            if item.kind == .link, let copy = localPageCopy(for: item) {
                let path = ExportNaming.unique(item.displayTitle, ext: "webarchive", in: folder, taken: &taken)
                record.pageCopy = path
                job.entries.append(.init(path: path, source: .file(copy), modified: item.archivedAt ?? item.modifiedAt))
            }
            // A document only needs a Markdown file for what's said about it.
            if item.kind != .document || !item.body.isEmpty || !record.highlights.isEmpty {
                let path = ExportNaming.unique(item.displayTitle + (item.kind == .document ? " (notes)" : ""),
                                               ext: "md", in: folder, taken: &taken)
                record.markdown = path
                let text = ExportMarkdown.render(record, category: item.category?.path ?? "")
                job.entries.append(.init(path: path, source: .data(Data(text.utf8)), modified: item.modifiedAt))
            }
            manifest.items.append(record)
        }
        job.entries.append(.init(path: BackupManifest.fileName, source: .data(try manifest.encoded()), modified: .now))
        return job
    }

    /// Adds whatever in the export isn't in the library already. Items that
    /// are (the same item, not just the same title) are left alone.
    func restore(from url: URL) async throws -> RestoreSummary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let zip = try ZipReader(data: try Data(contentsOf: url, options: .alwaysMapped))
        guard zip.contains(BackupManifest.fileName) else { throw BackupError.notABackup }
        let manifest = try BackupManifest.decode(try zip.data(for: BackupManifest.fileName, inflate: Inflater.inflate))

        let existingItems = Set(try context.fetch(FetchDescriptor<Item>()).map(\.uuid))
        let missing = manifest.items.filter { !existingItems.contains($0.id) }
        var summary = RestoreSummary(added: missing.count, skipped: manifest.items.count - missing.count)

        // Files first, off the main thread: they can be large.
        var copies: [(from: String, to: String)] = []
        for record in missing {
            if let file = record.file { copies.append((file, "\(record.id.uuidString)/" + Self.fileName(file))) }
            if let page = record.pageCopy { copies.append((page, "\(record.id.uuidString)/Page.webarchive")) }
        }
        let files = self.files
        let failed: Set<String> = await Task.detached(priority: .userInitiated) {
            var failed: Set<String> = []
            for copy in copies {
                do {
                    try files.write(try zip.data(for: copy.from, inflate: Inflater.inflate), to: copy.to)
                } catch {
                    failed.insert(copy.from)
                }
            }
            return failed
        }.value

        // Categories, then the items in them.
        var categories = Dictionary(try context.fetch(FetchDescriptor<ItemCategory>()).map { ($0.uuid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        for record in manifest.categories where categories[record.id] == nil {
            let category = ItemCategory(name: record.name)
            category.uuid = record.id
            context.insert(category)
            categories[record.id] = category
        }
        for record in manifest.categories {
            if let parent = record.parent, let category = categories[record.id], category.parent == nil,
               let found = categories[parent], found != category {
                category.parent = found
            }
        }

        let existingFilters = Set(try context.fetch(FetchDescriptor<SmartFilter>()).map(\.uuid))
        for record in manifest.smartFilters where !existingFilters.contains(record.id) {
            let filter = SmartFilter(name: record.name, query: record.query)
            filter.uuid = record.id
            filter.createdAt = record.createdAt
            context.insert(filter)
        }

        let existingRules = Set(try context.fetch(FetchDescriptor<SmartRule>()).map(\.uuid))
        for record in manifest.rules ?? [] where !existingRules.contains(record.id) {
            let rule = SmartRule(name: record.name)
            rule.uuid = record.id
            rule.query = record.query
            rule.isEnabled = record.isEnabled
            rule.createdAt = record.createdAt
            context.insert(rule)
            rule.category = record.category.flatMap { categories[$0] }
            rule.tagsToAdd = record.tags
            rule.labelRaw = record.label
            rule.rating = record.rating
            rule.makesFavorite = record.makesFavorite
            rule.marksRead = record.marksRead
            rule.takesOutOfInbox = record.takesOutOfInbox
        }

        var added: [Item] = []
        for record in missing {
            let item = Item(kind: ItemKind(rawValue: record.kind) ?? .note, title: record.title)
            item.uuid = record.id
            item.body = record.body
            item.summary = record.summary
            item.urlString = record.url
            item.createdAt = record.createdAt
            item.isFavorite = record.isFavorite
            item.trashedAt = record.trashedAt
            item.isUnread = record.isUnread
            item.inInbox = record.inInbox
            item.labelRaw = record.label
            item.rating = record.rating
            item.contentTypeIdentifier = record.contentType
            item.contentHash = record.contentHash
            item.extractedText = record.extractedText
            item.readingPosition = record.readingPosition
            context.insert(item)
            item.category = record.category.flatMap { categories[$0] }

            if let file = record.file, !failed.contains(file) {
                item.storedFilePath = "\(record.id.uuidString)/" + Self.fileName(file)
                item.fileData = syncableContents(of: item)
            }
            if let page = record.pageCopy, !failed.contains(page) {
                let path = "\(record.id.uuidString)/Page.webarchive"
                item.archivePath = path
                item.archivedAt = record.archivedAt
                if let data = try? Data(contentsOf: files.url(for: path), options: .mappedIfSafe),
                   data.count <= Self.largestSyncedFile {
                    item.archiveData = data
                }
            }
            for highlightRecord in record.highlights {
                let highlight = Highlight(text: highlightRecord.text,
                                          anchor: HighlightAnchor(json: highlightRecord.anchor) ?? .pdf([]),
                                          position: highlightRecord.position,
                                          color: HighlightColor(rawValue: highlightRecord.color) ?? .yellow)
                highlight.uuid = highlightRecord.id
                highlight.note = highlightRecord.note
                highlight.createdAt = highlightRecord.createdAt
                highlight.anchorJSON = highlightRecord.anchor
                context.insert(highlight)
                highlight.item = item
            }
            if !record.tags.isEmpty { addTags(from: record.tags.joined(separator: ","), to: item) }
            // Adding tags counts as an edit; put back when it was really last changed.
            item.modifiedAt = record.modifiedAt
            added.append(item)
        }

        // Links between items, now that they're all here.
        let everyItem = Dictionary(try context.fetch(FetchDescriptor<Item>()).map { ($0.uuid, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for record in missing {
            guard let item = everyItem[record.id] else { continue }
            let targets = record.linksTo.compactMap { everyItem[$0] }.filter { $0 != item }
            if !targets.isEmpty { item.linksTo = (item.linksTo ?? []) + targets }
        }

        save()
        refreshAfterStoreChange()
        summary.added = added.count
        return summary
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// A finished export, handed to the system's save panel.
struct ExportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { file in
            SentTransferredFile(file.url)
        }
    }
}

/// Asked for from a menu; `ContentView` does it and offers to save the result.
enum ExportRequest: Identifiable {
    case items([Item], name: String)
    case everything

    var id: String {
        switch self {
        case .items(let items, let name): name + items.map(\.uuid.uuidString).joined()
        case .everything: "everything"
        }
    }
}
