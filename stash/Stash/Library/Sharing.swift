import CloudKit
import Foundation
import SwiftData
import StashCore
import UniformTypeIdentifiers

/// Sharing categories with other people through iCloud, as Keep It does.
///
/// SwiftData's own sync only reaches your private database, so sharing goes
/// beside it, through CloudKit directly, with two `CKSyncEngine`s:
///
/// - **Yours** (the private database): each shared category is a zone of its
///   own, named for the category, holding a record per item in it (named by
///   the item's uuid) and one zone-wide share. What changes in shared
///   categories is sent; what people you share with change comes back.
/// - **Shared with you** (the shared database): zones others share arrive in
///   the *Shared with Me* library, a category each. Where you may make
///   changes, they're sent back to the owner.
///
/// Each side remembers the signature of what it last sent or took in for
/// each item (`SharedItemPayload.signature`), which tells an echo of its own
/// change from someone else's, and a change made here from one made there.
/// When both changed an item, the later change wins (`SharedMerge`), and the
/// other's note text is kept in the note's history.
///
/// Only with iCloud sync on (`ICLOUD_SYNC`): without the entitlement, CloudKit crashes.
@MainActor
final class Sharing {
    static let shared: Sharing? = SyncMonitor.isEnabled && !StashStore.isTestLibrary ? Sharing() : nil

    /// The container named in the entitlements, as SyncMonitor finds it.
    static let container: CKContainer? = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "StashICloudContainer") as? String,
              id.hasPrefix("iCloud.") else { return nil }
        return CKContainer(identifier: id)
    }()

    static let recordType = "SharedItem"

    private var mine: CKSyncEngine?
    private var theirs: CKSyncEngine?
    private var delegate: EngineDelegate?
    private let folder: URL
    /// Each record's system fields (its change tag), so a save replaces what's there.
    private var systemFields: [String: Data]
    /// What was last sent or taken in: zone → item → signature.
    private var sentMine: [String: [UUID: String]]
    private var sentTheirs: [String: [UUID: String]]
    private var pendingPublish: Task<Void, Never>?

    private init() {
        folder = Library.mainSupportFolder.appendingPathComponent("Sharing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        systemFields = Self.read([String: Data].self, from: folder.appendingPathComponent("SystemFields.plist")) ?? [:]
        sentMine = Self.read([String: [UUID: String]].self, from: folder.appendingPathComponent("SentMine.plist")) ?? [:]
        sentTheirs = Self.read([String: [UUID: String]].self, from: folder.appendingPathComponent("SentTheirs.plist")) ?? [:]
    }

    /// Starts both engines; at launch.
    func start() {
        guard let container = Self.container, mine == nil else { return }
        let delegate = EngineDelegate(sharing: self)
        self.delegate = delegate
        mine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: Self.read(CKSyncEngine.State.Serialization.self, from: stateURL(mine: true)),
            delegate: delegate))
        theirs = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: Self.read(CKSyncEngine.State.Serialization.self, from: stateURL(mine: false)),
            delegate: delegate))
        schedulePublish()
    }

    private func stateURL(mine isMine: Bool) -> URL {
        folder.appendingPathComponent(isMine ? "Mine.state" : "Theirs.state")
    }

    // MARK: - Stores

    /// Where items are read and written: the main library (yours), or the
    /// Shared with Me library (theirs), open in the window or on its own.
    @MainActor
    private struct Store {
        let context: ModelContext
        let files: FileStore
        /// The library, when it's the one open (its index, files and saving go through it).
        let library: Library?
        /// Kept alive while the store's used, when it isn't the open one.
        let container: ModelContainer?

        func save() {
            if let library { library.save() } else { try? context.save() }
        }

        func localFile(for item: Item) -> URL? {
            if let library { return library.localFile(for: item) }
            guard let path = item.storedFilePath, files.exists(path) else { return nil }
            return files.url(for: path)
        }
    }

    /// The main library, only while it's open: its store syncs through
    /// SwiftData, which a second container on it would upset.
    private func mainStore() -> Store? {
        let store = StashStore.shared
        guard store.current.isMain else { return nil }
        return Store(context: store.library.context, files: store.library.files, library: store.library, container: nil)
    }

    private func sharedStore() -> Store? {
        let store = StashStore.shared
        let info = store.ensureSharedLibrary()
        if store.current.isShared {
            return Store(context: store.library.context, files: store.library.files, library: store.library, container: nil)
        }
        guard let container = try? ModelContainer(for: StashStore.schema, configurations: StashStore.localConfiguration(for: info)) else {
            return nil
        }
        return Store(context: ModelContext(container),
                     files: FileStore(root: StashStore.supportFolder(for: info).appendingPathComponent("Files", isDirectory: true)),
                     library: nil, container: container)
    }

    private static func category(_ id: UUID, in context: ModelContext) -> ItemCategory? {
        ((try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == id }))) ?? []).first
    }

    private static func item(_ id: UUID, in context: ModelContext) -> Item? {
        ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.uuid == id }))) ?? []).first
    }

    private static func items(in category: ItemCategory, context: ModelContext) -> [Item] {
        ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt == nil }))) ?? [])
            .filter { category.contains($0.category) && !$0.isLocked && !$0.isSealed && !$0.isTemplate }
    }

    // MARK: - Sharing a category (yours)

    /// The category's share, made (with its zone) the first time.
    func prepareShare(for category: ItemCategory) async throws -> CKShare {
        guard let container = Self.container else { throw CKError(.notAuthenticated) }
        let database = container.privateCloudDatabase
        let zoneName = SharedZones.zoneName(forCategory: category.uuid)
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        if !category.sharedZoneName.isEmpty,
           let existing = try? await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare {
            return existing
        }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = category.name as CKRecordValue
        share.publicPermission = .none
        let (saved, _) = try await database.modifyRecords(saving: [share], deleting: [])
        guard case .success(let record)? = saved[share.recordID], let made = record as? CKShare else {
            throw CKError(.internalError)
        }
        category.sharedZoneName = zoneName
        mainStore()?.save()
        sentMine[zoneName] = [:]
        writeState()
        schedulePublish()
        return made
    }

    /// Who it's shared with, for the sharing sheet.
    func share(of category: ItemCategory) async -> CKShare? {
        guard let container = Self.container, !category.sharedZoneName.isEmpty else { return nil }
        let zoneID = CKRecordZone.ID(zoneName: category.sharedZoneName)
        return try? await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare
    }

    /// Stops sharing: the zone goes, and with it everyone else's copy.
    func stopSharing(_ category: ItemCategory) async throws {
        guard let container = Self.container, !category.sharedZoneName.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: category.sharedZoneName)
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        sentMine[category.sharedZoneName] = nil
        category.sharedZoneName = ""
        mainStore()?.save()
        writeState()
    }

    // MARK: - Shared with you (theirs)

    /// Accepting an invitation, from Messages, Mail or a link.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let container = Self.container else { return }
        do {
            _ = try await container.accept(metadata)
            StashStore.shared.ensureSharedLibrary()
            try await theirs?.fetchChanges()
        } catch {
            StashStore.shared.library.importError = "The invitation couldn’t be accepted: \(error.localizedDescription)"
        }
    }

    /// Leaves a category someone shared with you.
    func leave(_ category: ItemCategory) async throws {
        guard let container = Self.container, let zone = TheirZone(category.sharedZoneName) else { return }
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zone.id])
        removeTheirCategory(zone.name)
    }

    /// What a Shared with Me category keeps about its zone: "name|owner|rw" (or ro).
    struct TheirZone {
        let name: String
        let owner: String
        let canEdit: Bool

        init?(_ stored: String) {
            let parts = stored.split(separator: "|").map(String.init)
            guard parts.count >= 2 else { return nil }
            name = parts[0]
            owner = parts[1]
            canEdit = parts.count > 2 && parts[2] == "rw"
        }

        init(name: String, owner: String, canEdit: Bool) {
            self.name = name
            self.owner = owner
            self.canEdit = canEdit
        }

        var stored: String { [name, owner, canEdit ? "rw" : "ro"].joined(separator: "|") }
        var id: CKRecordZone.ID { CKRecordZone.ID(zoneName: name, ownerName: owner) }
        var key: String { name + "|" + owner }
    }

    private func applyShare(_ share: CKShare) {
        let zoneID = share.recordID.zoneID
        let title = (share[CKShare.SystemFieldKey.title] as? String) ?? "Shared"
        let owner = share.owner.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .short) }
        let canEdit = share.currentUserParticipant?.permission == .readWrite
        guard let store = sharedStore(), let id = SharedZones.categoryID(fromZone: zoneID.zoneName) else { return }
        let category = Self.category(id, in: store.context) ?? {
            let made = ItemCategory(name: title)
            made.uuid = id
            store.context.insert(made)
            return made
        }()
        category.name = owner.map { "\(title) (from \($0))" } ?? title
        category.sharedZoneName = TheirZone(name: zoneID.zoneName, owner: zoneID.ownerName, canEdit: canEdit).stored
        store.save()
    }

    /// The owner stopped sharing, or you left: the category and its items go.
    private func removeTheirCategory(_ zoneName: String) {
        guard let store = sharedStore(), let id = SharedZones.categoryID(fromZone: zoneName),
              let top = Self.category(id, in: store.context) else { return }
        if let zone = TheirZone(top.sharedZoneName) { sentTheirs[zone.key] = nil }
        for item in (try? store.context.fetch(FetchDescriptor<Item>())) ?? [] where top.contains(item.category) {
            store.context.delete(item)
        }
        store.context.delete(top)
        store.save()
        store.library?.refreshAfterStoreChange()
        writeState()
    }

    // MARK: - Sending what changed

    /// A few seconds after either library changes.
    func schedulePublish() {
        pendingPublish?.cancel()
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    /// Works out what's changed in each shared category since it was last
    /// sent or taken in, and asks the engines to send it.
    private func publish() {
        if let mine, let store = mainStore() {
            takeWaitingChanges(into: store)
            let categories = ((try? store.context.fetch(FetchDescriptor<ItemCategory>())) ?? [])
                .filter { !$0.sharedZoneName.isEmpty && TheirZone($0.sharedZoneName) == nil }
            for category in categories {
                let zoneID = CKRecordZone.ID(zoneName: category.sharedZoneName)
                sentMine[category.sharedZoneName] = enqueue(Self.items(in: category, context: store.context), top: category, store: store,
                                                            zoneID: zoneID, sent: sentMine[category.sharedZoneName] ?? [:], engine: mine)
            }
            // Categories deleted here: their zones go.
            let live = Set(categories.map(\.sharedZoneName))
            for zone in sentMine.keys where !live.contains(zone) {
                mine.state.add(pendingDatabaseChanges: [.deleteZone(CKRecordZone.ID(zoneName: zone))])
                sentMine[zone] = nil
            }
        }
        // Changes made to categories shared with you, where you may.
        if let theirs, StashStore.shared.current.isShared, let store = sharedStore() {
            let categories = ((try? store.context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.parent == nil }))) ?? [])
            for category in categories {
                guard let zone = TheirZone(category.sharedZoneName), zone.canEdit else { continue }
                sentTheirs[zone.key] = enqueue(Self.items(in: category, context: store.context), top: category, store: store,
                                               zoneID: zone.id, sent: sentTheirs[zone.key] ?? [:], engine: theirs)
            }
        }
        writeState()
    }

    /// Asks the engine to send what's changed; gives the signatures now, to remember.
    private func enqueue(_ items: [Item], top: ItemCategory, store: Store, zoneID: CKRecordZone.ID,
                         sent: [UUID: String], engine: CKSyncEngine) -> [UUID: String] {
        let now = Dictionary(items.map { ($0.uuid, Self.payload(for: $0, under: top, store: store).0.signature) },
                             uniquingKeysWith: { first, _ in first })
        let (save, delete) = SharedZones.changes(now: now, sent: sent)
        var changes: [CKSyncEngine.PendingRecordZoneChange] = save.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
        changes += delete.map { .deleteRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
        return now
    }

    /// The item as it's shared, and its file if it goes with it.
    private static func payload(for item: Item, under top: ItemCategory, store: Store) -> (SharedItemPayload, URL?) {
        let file = item.kind == .document ? store.localFile(for: item) : nil
        let size = (try? file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sendsFile = file != nil && size <= Library.largestSyncedFile
        let payload = SharedItemPayload(
            kind: item.kindRaw, title: item.title, body: item.body, url: item.urlString, summary: item.summary,
            extractedText: item.extractedText, createdAt: item.createdAt, modifiedAt: item.modifiedAt,
            tags: item.sortedTags.map(\.name), folders: folders(of: item, under: top),
            contentType: item.contentTypeIdentifier, fileName: sendsFile ? file?.lastPathComponent : nil,
            highlights: item.sortedHighlights.map {
                .init(id: $0.uuid, text: $0.text, note: $0.note, color: $0.colorRaw, customColor: $0.customColor,
                      anchor: $0.anchorJSON, position: $0.position, createdAt: $0.createdAt)
            })
        return (payload, sendsFile ? file : nil)
    }

    /// The categories between the shared one and the item, outermost first.
    private static func folders(of item: Item, under category: ItemCategory) -> [String] {
        var names: [String] = []
        var next = item.category
        while let current = next, current != category {
            names.insert(current.name, at: 0)
            next = current.parent
        }
        return names
    }

    /// The record for an item, when an engine's ready to send it; nil if
    /// it can't be made now (yours, with the main library not open).
    fileprivate func record(for id: CKRecord.ID, mine isMine: Bool) -> CKRecord? {
        guard let uuid = UUID(uuidString: id.recordName), let categoryID = SharedZones.categoryID(fromZone: id.zoneID.zoneName),
              let store = isMine ? mainStore() : sharedStore(),
              let item = Self.item(uuid, in: store.context), let top = Self.category(categoryID, in: store.context) else { return nil }
        let (payload, file) = Self.payload(for: item, under: top, store: store)
        guard let data = try? payload.encoded() else { return nil }
        let key = Self.fieldsKey(id)
        let record = systemFields[key].flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        if data.count < 700_000 {
            record["payload"] = data as CKRecordValue
            record["payloadFile"] = nil
        } else {
            // Too big for the record itself: sent as a file beside it.
            let url = folder.appendingPathComponent("Outbox", isDirectory: true).appendingPathComponent(key.replacingOccurrences(of: "/", with: "-") + ".json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            record["payload"] = nil
            record["payloadFile"] = CKAsset(fileURL: url)
        }
        record["file"] = file.map(CKAsset.init(fileURL:))
        return record
    }

    // MARK: - Taking in what changed elsewhere

    private func receive(_ record: CKRecord, mine isMine: Bool) {
        guard record.recordType == Self.recordType else { return }
        if isMine {
            // Changes to your categories, from people you share with.
            guard let store = mainStore() else { return keepForLater(record) }
            take(record, into: store, zoneKey: record.recordID.zoneID.zoneName, mine: true)
        } else if let store = sharedStore() {
            let zone = record.recordID.zoneID
            take(record, into: store, zoneKey: zone.zoneName + "|" + zone.ownerName, mine: false)
        }
    }

    /// What was last sent or taken in for an item.
    private func sentSignature(_ zoneKey: String, _ item: UUID, mine isMine: Bool) -> String? {
        isMine ? sentMine[zoneKey]?[item] : sentTheirs[zoneKey]?[item]
    }

    private func setSent(_ signature: String?, _ zoneKey: String, _ item: UUID, mine isMine: Bool) {
        if isMine { sentMine[zoneKey, default: [:]][item] = signature } else { sentTheirs[zoneKey, default: [:]][item] = signature }
    }

    private func take(_ record: CKRecord, into store: Store, zoneKey: String, mine isMine: Bool) {
        guard let uuid = UUID(uuidString: record.recordID.recordName),
              let categoryID = SharedZones.categoryID(fromZone: record.recordID.zoneID.zoneName),
              let top = Self.category(categoryID, in: store.context),
              let incoming = Self.payload(of: record) else { return }
        let existing = Self.item(uuid, in: store.context)
        let local = existing.map { Self.payload(for: $0, under: top, store: store).0 }
        let decision = SharedMerge.decide(incoming: incoming.signature, incomingModified: incoming.modifiedAt,
                                          sent: sentSignature(zoneKey, uuid, mine: isMine), local: local?.signature,
                                          localModified: existing?.modifiedAt)
        switch decision {
        case .ignore:
            if let local, local.signature == incoming.signature { setSent(incoming.signature, zoneKey, uuid, mine: isMine) }
            return
        case .keepLocal:
            // Theirs is older: kept in the note's history, and ours goes out again.
            if let existing, incoming.body != existing.body { Self.keepVersion(of: existing, title: incoming.title, body: incoming.body, in: store) }
            store.save()
            return
        case .apply:
            break
        }
        let item = existing ?? {
            let made = Item(kind: ItemKind(rawValue: incoming.kind) ?? .note, title: incoming.title)
            made.uuid = uuid
            store.context.insert(made)
            return made
        }()
        // Changed here too, and theirs is newer: ours goes into the history.
        if let local, local.signature != sentSignature(zoneKey, uuid, mine: isMine), local.body != incoming.body {
            Self.keepVersion(of: item, title: local.title, body: local.body, in: store)
        }
        let fileChanged = Self.write(incoming, file: (record["file"] as? CKAsset)?.fileURL, into: item, under: top, store: store)
        setSent(Self.payload(for: item, under: top, store: store).0.signature, zoneKey, uuid, mine: isMine)
        if let library = store.library {
            library.reindex(item)
            library.save()
            if fileChanged { Task { await library.fileDidChange(item) } }
            library.runSearch()
        } else {
            store.save()
        }
        writeState()
    }

    private static func payload(of record: CKRecord) -> SharedItemPayload? {
        if let inline = record["payload"] as? Data { return try? SharedItemPayload.decode(inline) }
        if let asset = record["payloadFile"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            return try? SharedItemPayload.decode(data)
        }
        return nil
    }

    /// Puts what was shared onto the item. Gives whether its file changed.
    private static func write(_ payload: SharedItemPayload, file: URL?, into item: Item, under top: ItemCategory, store: Store) -> Bool {
        let context = store.context
        item.kindRaw = payload.kind
        item.title = payload.title
        item.body = payload.body
        item.urlString = payload.url
        item.summary = payload.summary
        if !payload.extractedText.isEmpty { item.extractedText = payload.extractedText }
        item.createdAt = payload.createdAt
        item.contentTypeIdentifier = payload.contentType
        item.category = payload.folders.reduce(top) { parent, name in child(named: name, of: parent, in: context) }
        item.tags = payload.tags.map { tag(named: $0, in: context) }
        var fileChanged = false
        if let file, let name = payload.fileName {
            // The asset's file has a made-up name; the item keeps the real one.
            let named = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: file, to: named)) != nil, let path = try? store.files.importFile(at: named, for: item.uuid) {
                item.storedFilePath = path
                item.contentHash = ""
                fileChanged = true
            }
            try? FileManager.default.removeItem(at: named.deletingLastPathComponent())
        }
        // Highlights as sent: those gone are taken away.
        let wanted = Set(payload.highlights.map(\.id))
        for old in item.highlights ?? [] where !wanted.contains(old.uuid) { context.delete(old) }
        let existing = Dictionary((item.highlights ?? []).map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for sent in payload.highlights {
            let highlight = existing[sent.id] ?? {
                let made = Highlight(text: sent.text, anchor: HighlightAnchor(json: sent.anchor) ?? .pdf([]), position: sent.position,
                                     color: HighlightColor(rawValue: sent.color) ?? .yellow)
                made.uuid = sent.id
                context.insert(made)
                made.item = item
                return made
            }()
            highlight.text = sent.text
            highlight.note = sent.note
            highlight.colorRaw = sent.color
            highlight.customColor = sent.customColor
            highlight.anchorJSON = sent.anchor
            highlight.position = sent.position
            highlight.createdAt = sent.createdAt
        }
        // Last, so the edits above don't stamp it with now.
        item.modifiedAt = payload.modifiedAt
        return fileChanged
    }

    private static func keepVersion(of item: Item, title: String, body: String, in store: Store) {
        let version = NoteVersion(title: title, body: body, savedAt: .now)
        store.context.insert(version)
        version.item = item
    }

    private func removed(_ id: CKRecord.ID, mine isMine: Bool) {
        guard let uuid = UUID(uuidString: id.recordName) else { return }
        if isMine {
            // Someone you share with deleted it: into your Trash, not gone.
            guard let store = mainStore(), let library = store.library else { return }
            sentMine[id.zoneID.zoneName]?[uuid] = nil
            if let item = Self.item(uuid, in: store.context) { library.moveToTrash([item]) }
        } else if let store = sharedStore() {
            sentTheirs[id.zoneID.zoneName + "|" + id.zoneID.ownerName]?[uuid] = nil
            if let item = Self.item(uuid, in: store.context) { store.context.delete(item) }
            store.save()
            store.library?.refreshAfterStoreChange()
        }
        writeState()
    }

    private static func child(named name: String, of parent: ItemCategory, in context: ModelContext) -> ItemCategory {
        if let found = (parent.children ?? []).first(where: { $0.name == name }) { return found }
        let made = ItemCategory(name: name)
        context.insert(made)
        made.parent = parent
        return made
    }

    private static func tag(named name: String, in context: ModelContext) -> Tag {
        let key = TagName.key(name)
        if let found = ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).first(where: { $0.key == key }) { return found }
        let made = Tag(name: name)
        context.insert(made)
        return made
    }

    // MARK: - Changes waiting for the main library

    private var waitingFolder: URL { folder.appendingPathComponent("Waiting", isDirectory: true) }

    /// A change to your categories that arrived while another library was
    /// open: kept, files and all, until the main one is.
    private func keepForLater(_ record: CKRecord) {
        try? FileManager.default.createDirectory(at: waitingFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString
        for key in ["file", "payloadFile"] {
            guard let asset = record[key] as? CKAsset, let url = asset.fileURL else { continue }
            let copy = waitingFolder.appendingPathComponent("\(name)-\(key)")
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { record[key] = CKAsset(fileURL: copy) }
        }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true) {
            try? data.write(to: waitingFolder.appendingPathComponent(name + ".record"))
        }
    }

    private func takeWaitingChanges(into store: Store) {
        let files = (try? FileManager.default.contentsOfDirectory(at: waitingFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let records = files.filter { $0.pathExtension == "record" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !records.isEmpty else { return }
        for url in records {
            if let data = try? Data(contentsOf: url),
               let record = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) {
                take(record, into: store, zoneKey: record.recordID.zoneID.zoneName, mine: true)
            }
        }
        try? FileManager.default.removeItem(at: waitingFolder)
    }

    // MARK: - Engine events

    fileprivate func handle(_ event: CKSyncEngine.Event, mine isMine: Bool) {
        switch event {
        case .stateUpdate(let update):
            Self.write(update.stateSerialization, to: stateURL(mine: isMine))
        case .accountChange(let change):
            if case .signOut = change.changeType {
                // Someone else's iCloud: start again.
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                systemFields = [:]
                sentMine = [:]
                sentTheirs = [:]
            }
        case .fetchedDatabaseChanges(let changes) where !isMine:
            for deletion in changes.deletions { removeTheirCategory(deletion.zoneID.zoneName) }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                systemFields[Self.fieldsKey(record.recordID)] = Self.systemFields(of: record)
                if let share = record as? CKShare {
                    if !isMine { applyShare(share) }
                } else {
                    receive(record, mine: isMine)
                }
            }
            for deletion in changes.deletions where deletion.recordType == Self.recordType {
                removed(deletion.recordID, mine: isMine)
            }
            writeState()
        case .sentRecordZoneChanges(let sent):
            let engine = isMine ? mine : theirs
            for record in sent.savedRecords {
                systemFields[Self.fieldsKey(record.recordID)] = Self.systemFields(of: record)
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Changed elsewhere first: weigh theirs against ours, then send ours if it still wins.
                    if let server = failure.error.serverRecord {
                        systemFields[Self.fieldsKey(id)] = Self.systemFields(of: server)
                        receive(server, mine: isMine)
                    }
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .zoneNotFound where isMine:
                    mine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                    mine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    systemFields[Self.fieldsKey(id)] = nil
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                default:
                    break
                }
            }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Outbox"))
            writeState()
        default:
            break
        }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let isMine = engine === mine
        // Yours wait while the main library isn't open: there's nothing to make them from.
        if isMine, mainStore() == nil { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending.prefix(200))) { id in
            await MainActor.run { self.record(for: id, mine: isMine) }
        }
    }

    /// Only the zones that are Stash's: SwiftData's own zone is left to SwiftData.
    fileprivate func fetchOptions(mine isMine: Bool) -> CKSyncEngine.FetchChangesOptions {
        guard isMine else { return CKSyncEngine.FetchChangesOptions() }
        return CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(sentMine.keys.map { CKRecordZone.ID(zoneName: $0) }))
    }

    fileprivate func isMine(_ engine: CKSyncEngine) -> Bool { engine === mine }

    // MARK: - Keeping state

    private static func fieldsKey(_ id: CKRecord.ID) -> String {
        id.zoneID.zoneName + "/" + id.zoneID.ownerName + "/" + id.recordName
    }

    private func writeState() {
        Self.write(systemFields, to: folder.appendingPathComponent("SystemFields.plist"))
        Self.write(sentMine, to: folder.appendingPathComponent("SentMine.plist"))
        Self.write(sentTheirs, to: folder.appendingPathComponent("SentTheirs.plist"))
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(Value.self, from: $0) }
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) {
        try? PropertyListEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// The engines' delegate: hands each event to Sharing, on the main actor.
private final class EngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    weak var sharing: Sharing?

    init(sharing: Sharing) {
        self.sharing = sharing
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run {
            guard let sharing else { return }
            sharing.handle(event, mine: sharing.isMine(syncEngine))
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let sharing = await MainActor.run(body: { self.sharing }) else { return nil }
        return await sharing.nextBatch(context, engine: syncEngine)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        await MainActor.run {
            guard let sharing else { return CKSyncEngine.FetchChangesOptions() }
            return sharing.fetchOptions(mine: sharing.isMine(syncEngine))
        }
    }
}
