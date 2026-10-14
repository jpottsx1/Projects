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
            categories: categories.map { category in
                var record = BackupManifest.Category(id: category.uuid, name: category.name, parent: category.parent?.uuid,
                                                     color: category.colorRaw == 0 ? nil : category.colorRaw,
                                                     order: category.order == 0 ? nil : category.order)
                record.isImportDestination = category.isImportDestination ? true : nil
                return record
            })
        if everything {
            manifest.smartFilters = try context.fetch(FetchDescriptor<SmartFilter>())
                .map { filter in
                    var record = BackupManifest.SmartFilterRecord(id: filter.uuid, name: filter.name, query: filter.query,
                                                                  createdAt: filter.createdAt)
                    record.order = filter.order == 0 ? nil : filter.order
                    record.categoryID = filter.category?.uuid
                    record.listID = filter.list?.uuid
                    return record
                }
            manifest.lists = try context.fetch(FetchDescriptor<ItemList>()).map {
                .init(id: $0.uuid, name: $0.name, order: $0.orderedItems.map(\.uuid), createdAt: $0.createdAt)
            }
            manifest.fields = try context.fetch(FetchDescriptor<FieldDefinition>()).map {
                .init(id: $0.uuid, name: $0.name, kind: $0.kindRaw, choices: $0.choices, order: $0.order)
            }
            manifest.feeds = try context.fetch(FetchDescriptor<Feed>()).map {
                .init(id: $0.uuid, title: $0.title, url: $0.urlString, siteURL: $0.siteURLString,
                      category: $0.categoryID, seenIDs: $0.seenIDs, addedAt: $0.addedAt)
            }
            manifest.rules = try context.fetch(FetchDescriptor<SmartRule>()).map { rule in
                var record = BackupManifest.RuleRecord(
                    id: rule.uuid, name: rule.name, query: rule.query, isEnabled: rule.isEnabled, createdAt: rule.createdAt,
                    category: rule.category?.uuid, tags: rule.tagsToAdd, label: rule.labelRaw, rating: rule.rating,
                    makesFavorite: rule.makesFavorite, marksRead: rule.marksRead, takesOutOfInbox: rule.takesOutOfInbox)
                record.schedule = rule.schedule == .never ? nil : rule.scheduleRaw
                record.runsAtLaunch = rule.runsAtLaunch ? true : nil
                return record
            }
        }

        var job = ExportJob()
        var taken: Set<String> = [BackupManifest.fileName.lowercased()]
        var usedVaults: Set<UUID> = []
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
            record.isTemplate = item.isTemplate ? true : nil
            record.feed = item.feed?.uuid
            record.isMindMap = item.isMindMap ? true : nil
            record.lastViewedAt = item.lastViewedAt
            record.sourceAddress = item.sourceAddress
            record.aliases = item.aliases.isEmpty ? nil : item.aliases
            if !item.calendarEventID.isEmpty {
                record.calendarEventID = item.calendarEventID
                record.calendarEventTitle = item.calendarEventTitle
                record.calendarEventStart = item.calendarEventStart
            }
            let pictureText = Dictionary((item.attachments ?? []).filter { !$0.recognizedText.isEmpty }
                .map { ($0.fileName, $0.recognizedText) }, uniquingKeysWith: { first, _ in first })
            record.pictureText = pictureText.isEmpty ? nil : pictureText
            let listIDs = (item.lists ?? []).map(\.uuid)
            record.lists = listIDs.isEmpty ? nil : listIDs
            record.customFields = item.customFields.isEmpty ? nil : item.customFields
            record.readLaterAt = item.readLaterAt
            record.readingProgress = item.readingProgress > 0 ? item.readingProgress : nil
            record.feedEntryID = item.feedEntryID.isEmpty ? nil : item.feedEntryID
            record.archivedAt = item.archivedAt
            record.highlights = item.sortedHighlights.map {
                .init(id: $0.uuid, text: $0.text, note: $0.note, color: $0.colorRaw, anchor: $0.anchorJSON,
                      position: $0.position, createdAt: $0.createdAt, customColor: $0.customColor.isEmpty ? nil : $0.customColor)
            }

            var folder = manifest.folder(for: item.category?.uuid)
            if item.isTrashed { folder = folder.isEmpty ? "Trash" : "Trash/" + folder }

            // Locked items go out as they're kept: encrypted, never decrypted copies.
            let isSealed = item.isSealed
            if isSealed {
                record.sealed = item.sealedData
                record.sealedVault = item.sealedVaultID
                if let id = item.sealedVaultID { usedVaults.insert(id) }
            }
            if item.kind == .document,
               let file = isSealed ? storedCopy(item.storedFilePath, synced: item.fileData) : localFile(for: item) {
                let ext = isSealed ? file.pathExtension + Self.sealedSuffix : file.pathExtension
                let path = ExportNaming.unique(item.displayTitle, ext: ext, in: folder, taken: &taken)
                record.file = path
                job.entries.append(.init(path: path, source: .file(file), modified: item.modifiedAt))
            }
            if item.kind == .link,
               let copy = isSealed ? storedCopy(item.archivePath, synced: item.archiveData) : localPageCopy(for: item) {
                let path = ExportNaming.unique(item.displayTitle, ext: "webarchive" + (isSealed ? Self.sealedSuffix : ""),
                                               in: folder, taken: &taken)
                record.pageCopy = path
                job.entries.append(.init(path: path, source: .file(copy), modified: item.archivedAt ?? item.modifiedAt))
            }
            // A note's pictures, in a folder beside it.
            var readable = record
            let attachments = item.attachments ?? []
            if !attachments.isEmpty {
                let picturesFolder = ExportNaming.unique(item.displayTitle + " files", ext: "", in: folder, taken: &taken)
                var paths: [String: String] = [:]
                for attachment in attachments {
                    let source = isSealed
                        ? storedCopy("\(item.uuid.uuidString)/Attachments/\(attachment.fileName)", synced: attachment.data)
                        : pictureURL(Self.attachmentScheme + attachment.fileName, in: item)
                    guard let url = source else { continue }
                    let path = picturesFolder + "/" + attachment.fileName
                    job.entries.append(.init(path: path, source: .file(url), modified: attachment.createdAt))
                    paths[attachment.fileName] = path
                    // In the readable copy, pictures point at the folder.
                    let relative = String(path.dropFirst(folder.isEmpty ? 0 : folder.count + 1))
                    readable.body = readable.body.replacingOccurrences(
                        of: Self.attachmentScheme + attachment.fileName,
                        with: relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative)
                }
                record.attachments = paths
            }
            // A document only needs a Markdown file for what's said about it.
            if !isSealed, item.kind != .document || !item.body.isEmpty || !record.highlights.isEmpty {
                let path = ExportNaming.unique(item.displayTitle + (item.kind == .document ? " (notes)" : ""),
                                               ext: "md", in: folder, taken: &taken)
                record.markdown = path
                let text = ExportMarkdown.render(readable, category: item.category?.path ?? "")
                job.entries.append(.init(path: path, source: .data(Data(text.utf8)), modified: item.modifiedAt))
            }
            manifest.items.append(record)
        }
        if !usedVaults.isEmpty {
            manifest.vaults = try context.fetch(FetchDescriptor<Vault>()).filter { usedVaults.contains($0.uuid) }.compactMap { vault in
                guard let salt = vault.salt, let wrapped = vault.wrappedKey else { return nil }
                return .init(id: vault.uuid, salt: salt, rounds: vault.rounds, wrappedKey: wrapped, createdAt: vault.createdAt)
            }
        }
        job.entries.append(.init(path: BackupManifest.fileName, source: .data(try manifest.encoded()), modified: .now))
        return job
    }

    /// Added to an encrypted file's name in an export, so nothing takes it
    /// for the real thing.
    static let sealedSuffix = ".sealed"

    /// The file as kept (for a locked item, encrypted), written out from its
    /// synced copy if it isn't on this device yet.
    private func storedCopy(_ path: String?, synced: Data?) -> URL? {
        guard let path else { return nil }
        if !files.exists(path), let synced { try? files.write(synced, to: path) }
        return files.exists(path) ? files.url(for: path) : nil
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
            for (name, path) in record.attachments ?? [:] {
                copies.append((path, "\(record.id.uuidString)/Attachments/\(name)"))
            }
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
            category.colorRaw = record.color ?? 0
            category.order = record.order ?? 0
            category.isImportDestination = record.isImportDestination ?? false
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
        var restoredFilters: [(SmartFilter, UUID)] = []
        for record in manifest.smartFilters where !existingFilters.contains(record.id) {
            let filter = SmartFilter(name: record.name, query: record.query)
            filter.uuid = record.id
            filter.order = record.order ?? 0
            filter.createdAt = record.createdAt
            context.insert(filter)
            filter.category = record.categoryID.flatMap { categories[$0] }
            if let list = record.listID { restoredFilters.append((filter, list)) }
        }

        // Fields and lists, before the items that use them.
        let existingFields = Set(try context.fetch(FetchDescriptor<FieldDefinition>()).map(\.uuid))
        for record in manifest.fields ?? [] where !existingFields.contains(record.id) {
            let field = FieldDefinition(name: record.name, kind: CustomField.Kind(rawValue: record.kind) ?? .text, order: record.order)
            field.uuid = record.id
            field.choices = record.choices
            context.insert(field)
        }
        var listsByID = Dictionary(try context.fetch(FetchDescriptor<ItemList>()).map { ($0.uuid, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for record in manifest.lists ?? [] where listsByID[record.id] == nil {
            let list = ItemList(name: record.name)
            list.uuid = record.id
            list.order = record.order
            list.createdAt = record.createdAt
            context.insert(list)
            listsByID[record.id] = list
        }
        for (filter, listID) in restoredFilters { filter.list = listsByID[listID] }

        // The keys locked items need, still under their passwords.
        let existingVaults = Set(try context.fetch(FetchDescriptor<Vault>()).map(\.uuid))
        for record in manifest.vaults ?? [] where !existingVaults.contains(record.id) {
            let vault = Vault(salt: record.salt, rounds: record.rounds, wrappedKey: record.wrappedKey)
            vault.uuid = record.id
            vault.createdAt = record.createdAt
            context.insert(vault)
        }

        // Feeds already followed (by address) aren't added again.
        var feedsByID: [UUID: Feed] = [:]
        let existingFeeds = try context.fetch(FetchDescriptor<Feed>())
        for record in manifest.feeds ?? [] {
            if let existing = existingFeeds.first(where: { $0.uuid == record.id || $0.urlString == record.url }) {
                existing.markSeen(record.seenIDs.split(separator: "\n").map(String.init).reversed())
                feedsByID[record.id] = existing
                continue
            }
            guard let url = URL(string: record.url) else { continue }
            let feed = Feed(title: record.title, url: url)
            feed.uuid = record.id
            feed.siteURLString = record.siteURL
            feed.categoryID = record.category
            feed.seenIDs = record.seenIDs
            feed.addedAt = record.addedAt
            context.insert(feed)
            feedsByID[record.id] = feed
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
            rule.scheduleRaw = record.schedule ?? RuleSchedule.never.rawValue
            rule.runsAtLaunch = record.runsAtLaunch ?? false
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
            item.isTemplate = record.isTemplate ?? false
            item.feedEntryID = record.feedEntryID ?? ""
            item.sealedData = record.sealed
            item.sealedVaultID = record.sealedVault
            context.insert(item)
            item.category = record.category.flatMap { categories[$0] }
            item.feed = record.feed.flatMap { feedsByID[$0] }
            item.isMindMap = record.isMindMap ?? false
            item.lastViewedAt = record.lastViewedAt
            item.sourceAddress = record.sourceAddress
            item.aliases = record.aliases ?? ""
            item.calendarEventID = record.calendarEventID ?? ""
            item.calendarEventTitle = record.calendarEventTitle ?? ""
            item.calendarEventStart = record.calendarEventStart
            item.lists = (record.lists ?? []).compactMap { listsByID[$0] }
            item.customFields = record.customFields ?? ""
            item.readLaterAt = record.readLaterAt
            item.readingProgress = record.readingProgress ?? 0

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
            for (name, path) in record.attachments ?? [:] where !failed.contains(path) {
                let stored = files.url(for: "\(record.id.uuidString)/Attachments/\(name)")
                guard let data = try? Data(contentsOf: stored) else { continue }
                let attachment = NoteAttachment(fileName: name, data: data)
                attachment.recognizedText = record.pictureText?[name] ?? ""
                context.insert(attachment)
                attachment.item = item
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
                highlight.customColor = highlightRecord.customColor ?? ""
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
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(sealedSuffix) ? String(name.dropLast(sealedSuffix.count)) : name
    }
}

/// Asked for from a menu; `ContentView` does it and offers to save the result.
enum ExportRequest: Identifiable {
    case items([Item], name: String)
    case everything
    /// Every highlight in the library, as one Markdown file.
    case highlights

    var id: String {
        switch self {
        case .highlights: "highlights"
        case .items(let items, let name): name + items.map(\.uuid.uuidString).joined()
        case .everything: "everything"
        }
    }
}
