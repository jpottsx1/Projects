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
///   the item's uuid) and one zone-wide share. As the library changes, what
///   changed in shared categories is sent.
/// - **Shared with you** (the shared database): zones others share arrive in
///   the *Shared with Me* library, a category each, read only for now.
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
    private static let biggestFile = Library.largestSyncedFile

    private var mine: CKSyncEngine?
    private var theirs: CKSyncEngine?
    private let folder: URL
    /// Each record's system fields (its change tag), so a save replaces what's there.
    private var systemFields: [String: Data]
    /// What was last sent from each shared category: item uuid → signature.
    private var sent: [String: [UUID: String]]
    private var pendingPublish: Task<Void, Never>?

    private init() {
        folder = Library.mainSupportFolder.appendingPathComponent("Sharing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        systemFields = Self.read([String: Data].self, from: folder.appendingPathComponent("SystemFields.plist")) ?? [:]
        sent = Self.read([String: [UUID: String]].self, from: folder.appendingPathComponent("Sent.plist")) ?? [:]
    }

    /// Starts both engines; at launch, from the main library.
    func start() {
        guard let container = Self.container, mine == nil else { return }
        let delegate = EngineDelegate(sharing: self)
        self.delegate = delegate
        mine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: Self.read(CKSyncEngine.State.Serialization.self, from: stateURL(private: true)),
            delegate: delegate))
        theirs = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: Self.read(CKSyncEngine.State.Serialization.self, from: stateURL(private: false)),
            delegate: delegate))
        schedulePublish()
    }

    private var delegate: EngineDelegate?

    private func stateURL(private isPrivate: Bool) -> URL {
        folder.appendingPathComponent(isPrivate ? "Mine.state" : "Theirs.state")
    }

    private var mainLibrary: Library? {
        let store = StashStore.shared
        return store.current.isMain ? store.library : nil
    }

    // MARK: - Sharing a category

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
        mainLibrary?.save()
        sent[zoneName] = [:]
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
        sent[category.sharedZoneName] = nil
        category.sharedZoneName = ""
        mainLibrary?.save()
        writeState()
    }

    // MARK: - Sending what changed

    /// A few seconds after the main library changes.
    func schedulePublish() {
        pendingPublish?.cancel()
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    /// Works out what's changed in each shared category since it was last
    /// sent, and asks the engine to send it.
    private func publish() {
        guard let mine, let library = mainLibrary else { return }
        let categories = ((try? library.context.fetch(FetchDescriptor<ItemCategory>())) ?? []).filter { !$0.sharedZoneName.isEmpty }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for category in categories {
            let zoneID = CKRecordZone.ID(zoneName: category.sharedZoneName)
            let items = library.items(in: category).filter { !$0.isLocked && !$0.isSealed && !$0.isTemplate }
            let now = Dictionary(items.map { ($0.uuid, Self.signature(of: $0, in: category)) }, uniquingKeysWith: { first, _ in first })
            let (save, delete) = SharedZones.changes(now: now, sent: sent[category.sharedZoneName] ?? [:])
            changes += save.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
            changes += delete.map { .deleteRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
            sent[category.sharedZoneName] = now
        }
        // Categories no longer shared from this device's point of view (deleted): their records go.
        let live = Set(categories.map(\.sharedZoneName))
        for zone in sent.keys where !live.contains(zone) {
            mine.state.add(pendingDatabaseChanges: [.deleteZone(CKRecordZone.ID(zoneName: zone))])
            sent[zone] = nil
        }
        guard !changes.isEmpty else { writeState(); return }
        mine.state.add(pendingRecordZoneChanges: changes)
        writeState()
    }

    /// Changes whenever anything shared about the item does.
    private static func signature(of item: Item, in category: ItemCategory) -> String {
        [Library.indexSignature(item), folders(of: item, under: category).joined(separator: "/"), item.contentHash,
         (item.highlights ?? []).map { $0.uuid.uuidString + $0.colorRaw }.sorted().joined()].joined(separator: "|")
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

    /// The record for an item, when the engine's ready to send it.
    fileprivate func record(for id: CKRecord.ID) -> CKRecord? {
        guard let library = mainLibrary, let uuid = UUID(uuidString: id.recordName),
              let item = library.items(withIDs: [uuid]).first,
              let categoryID = SharedZones.categoryID(fromZone: id.zoneID.zoneName),
              let category = ((try? library.context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == categoryID }))) ?? []).first
        else { return nil }

        let record = systemFields[id.recordName].flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        let file = item.kind == .document ? library.localFile(for: item) : nil
        let fileSize = (try? file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sendsFile = file != nil && fileSize <= Self.biggestFile
        let payload = SharedItemPayload(
            kind: item.kindRaw, title: item.title, body: item.body, url: item.urlString, summary: item.summary,
            extractedText: item.extractedText, createdAt: item.createdAt, modifiedAt: item.modifiedAt,
            tags: item.sortedTags.map(\.name), folders: Self.folders(of: item, under: category),
            contentType: item.contentTypeIdentifier, fileName: sendsFile ? file?.lastPathComponent : nil,
            highlights: item.sortedHighlights.map {
                .init(id: $0.uuid, text: $0.text, note: $0.note, color: $0.colorRaw, customColor: $0.customColor,
                      anchor: $0.anchorJSON, position: $0.position, createdAt: $0.createdAt)
            })
        guard let data = try? payload.encoded() else { return nil }
        if data.count < 700_000 {
            record["payload"] = data as CKRecordValue
            record["payloadFile"] = nil
        } else {
            // Too big for the record itself: sent as a file beside it.
            let url = folder.appendingPathComponent("Outbox", isDirectory: true).appendingPathComponent(id.recordName + ".json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            record["payload"] = nil
            record["payloadFile"] = CKAsset(fileURL: url)
        }
        record["file"] = sendsFile ? file.map(CKAsset.init(fileURL:)) : nil
        return record
    }

    // MARK: - Taking in what's shared with you

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
    func leave(zoneNamed zoneName: String, ownedBy owner: String) async throws {
        guard let container = Self.container else { return }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        removeSharedCategory(zoneName: zoneName)
    }

    /// Runs `change` on the Shared with Me library's store: the open one if
    /// it's showing, otherwise a context of its own.
    private func withSharedStore(_ change: (ModelContext, FileStore) -> Void) {
        let store = StashStore.shared
        let info = store.ensureSharedLibrary()
        if store.current.isShared {
            change(store.library.context, store.library.files)
            store.library.save()
            store.library.refreshAfterStoreChange()
            return
        }
        guard let container = try? ModelContainer(for: StashStore.schema, configurations: StashStore.localConfiguration(for: info)) else { return }
        let context = ModelContext(container)
        change(context, FileStore(root: StashStore.supportFolder(for: info).appendingPathComponent("Files", isDirectory: true)))
        try? context.save()
    }

    /// The top category for a share: the owner's category's uuid, so it's found again.
    private static func topCategory(zoneName: String, in context: ModelContext) -> ItemCategory? {
        guard let id = SharedZones.categoryID(fromZone: zoneName) else { return nil }
        return ((try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.uuid == id }))) ?? []).first
    }

    fileprivate func applyShare(_ share: CKShare) {
        let zoneName = share.recordID.zoneID.zoneName
        let title = (share[CKShare.SystemFieldKey.title] as? String) ?? "Shared"
        let owner = share.owner.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .short) }
        withSharedStore { context, _ in
            let category = Self.topCategory(zoneName: zoneName, in: context) ?? {
                let made = ItemCategory(name: title)
                made.uuid = SharedZones.categoryID(fromZone: zoneName) ?? UUID()
                context.insert(made)
                return made
            }()
            category.name = owner.map { "\(title) (from \($0))" } ?? title
            category.sharedZoneName = zoneName + "|" + share.recordID.zoneID.ownerName
        }
    }

    fileprivate func applyRecord(_ record: CKRecord) {
        guard record.recordType == Self.recordType, let uuid = UUID(uuidString: record.recordID.recordName) else { return }
        let data: Data?
        if let inline = record["payload"] as? Data {
            data = inline
        } else if let asset = record["payloadFile"] as? CKAsset, let url = asset.fileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data, let payload = try? SharedItemPayload.decode(data) else { return }
        let zoneName = record.recordID.zoneID.zoneName
        let fileURL = (record["file"] as? CKAsset)?.fileURL
        withSharedStore { context, files in
            guard let top = Self.topCategory(zoneName: zoneName, in: context) else { return }
            let item = ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.uuid == uuid }))) ?? []).first ?? {
                let made = Item(kind: ItemKind(rawValue: payload.kind) ?? .note, title: payload.title)
                made.uuid = uuid
                context.insert(made)
                return made
            }()
            item.kindRaw = payload.kind
            item.title = payload.title
            item.body = payload.body
            item.urlString = payload.url
            item.summary = payload.summary
            item.extractedText = payload.extractedText
            item.createdAt = payload.createdAt
            item.modifiedAt = payload.modifiedAt
            item.contentTypeIdentifier = payload.contentType
            item.category = payload.folders.reduce(top) { parent, name in Self.child(named: name, of: parent, in: context) }
            item.tags = payload.tags.map { Self.tag(named: $0, in: context) }
            if let fileURL, let name = payload.fileName {
                // The asset's file has a made-up name; the item keeps the real one.
                let named = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: fileURL, to: named)) != nil {
                    item.storedFilePath = try? files.importFile(at: named, for: uuid)
                    item.contentHash = ""
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
        }
    }

    fileprivate func removeRecord(_ id: CKRecord.ID) {
        guard let uuid = UUID(uuidString: id.recordName) else { return }
        withSharedStore { context, _ in
            for item in (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.uuid == uuid }))) ?? [] {
                context.delete(item)
            }
        }
    }

    /// The owner stopped sharing, or you left: the category and its items go.
    fileprivate func removeSharedCategory(zoneName: String) {
        withSharedStore { context, _ in
            guard let top = Self.topCategory(zoneName: zoneName, in: context) else { return }
            let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
            for item in items where top.contains(item.category) { context.delete(item) }
            context.delete(top)
        }
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

    // MARK: - Engine events

    fileprivate func handle(_ event: CKSyncEngine.Event, isMine: Bool) {
        switch event {
        case .stateUpdate(let update):
            Self.write(update.stateSerialization, to: stateURL(private: isMine))
        case .accountChange(let change):
            if case .signOut = change.changeType {
                // Someone else's iCloud: start again.
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                systemFields = [:]
                sent = [:]
            }
        case .fetchedDatabaseChanges(let changes) where !isMine:
            for deletion in changes.deletions { removeSharedCategory(zoneName: deletion.zoneID.zoneName) }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                systemFields[record.recordID.recordName] = Self.systemFields(of: record)
                guard !isMine else { continue }
                if let share = record as? CKShare { applyShare(share) } else { applyRecord(record) }
            }
            if !isMine { for deletion in changes.deletions { removeRecord(deletion.recordID) } }
            writeState()
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                systemFields[record.recordID.recordName] = Self.systemFields(of: record)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("Outbox/\(record.recordID.recordName).json"))
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Changed on another of your devices: take its change tag and send ours again.
                    if let server = failure.error.serverRecord { systemFields[id.recordName] = Self.systemFields(of: server) }
                    mine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .zoneNotFound:
                    mine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                    mine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    systemFields[id.recordName] = nil
                    mine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                default:
                    break
                }
            }
            writeState()
        default:
            break
        }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending.prefix(200))) { id in
            await MainActor.run { self.record(for: id) }
        }
    }

    /// Only the zones that are Stash's: SwiftData's own zone is left to SwiftData.
    fileprivate func fetchOptions(isMine: Bool) -> CKSyncEngine.FetchChangesOptions {
        guard isMine else { return CKSyncEngine.FetchChangesOptions() }
        let zones = sent.keys.map { CKRecordZone.ID(zoneName: $0) }
        return CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(zones))
    }

    fileprivate func isMine(_ engine: CKSyncEngine) -> Bool { engine === mine }

    // MARK: - Keeping state

    private func writeState() {
        Self.write(systemFields, to: folder.appendingPathComponent("SystemFields.plist"))
        Self.write(sent, to: folder.appendingPathComponent("Sent.plist"))
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
            sharing.handle(event, isMine: sharing.isMine(syncEngine))
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let sharing = await MainActor.run(body: { self.sharing }) else { return nil }
        return await sharing.nextBatch(context, engine: syncEngine)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        await MainActor.run {
            guard let sharing else { return CKSyncEngine.FetchChangesOptions() }
            return sharing.fetchOptions(isMine: sharing.isMine(syncEngine))
        }
    }
}
