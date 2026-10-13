import Foundation

/// What Stash shows in the Finder (and Files, and Open and Save dialogs),
/// through its File Provider extension. As with sharing, the extension never
/// opens the library: the app publishes a snapshot of folders and files into
/// the App Group, with each file's contents beside it, and the extension
/// serves those. Changes made in the Finder go the other way, as requests
/// the app carries out.
public struct FinderEntry: Codable, Equatable {
    public static let rootID = "root"

    /// "c-<uuid>" for a category's folder, "i-<uuid>" for an item's file.
    public var id: String
    public var parent: String
    public var name: String
    public var isFolder: Bool
    public var size: Int
    public var created: Date
    public var modified: Date
    /// Where the file's contents are, inside the share's Content folder.
    public var contentPath: String?

    public init(id: String, parent: String, name: String, isFolder: Bool, size: Int = 0,
                created: Date, modified: Date, contentPath: String? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.created = created
        self.modified = modified
        self.contentPath = contentPath
    }

    /// The category or item it stands for.
    public var uuid: UUID? { UUID(uuidString: String(id.dropFirst(2))) }
    public var isCategory: Bool { id.hasPrefix("c-") }
}

public struct FinderSnapshot: Codable, Equatable {
    /// Goes up with every snapshot: the extension's sync anchor.
    public var version: Int
    public var entries: [FinderEntry]

    public init(version: Int, entries: [FinderEntry]) {
        self.version = version
        self.entries = entries
    }

    public func children(of parent: String) -> [FinderEntry] {
        entries.filter { $0.parent == parent }
    }

    public func entry(_ id: String) -> FinderEntry? {
        entries.first { $0.id == id }
    }

    /// Names made unique within each folder, as the Finder needs: a second
    /// "Notes.md" becomes "Notes 2.md".
    public static func uniquelyNamed(_ entries: [FinderEntry]) -> [FinderEntry] {
        var taken: [String: Set<String>] = [:]
        return entries.map { entry in
            var entry = entry
            let ext = (entry.name as NSString).pathExtension
            let base = ext.isEmpty || entry.isFolder ? entry.name : (entry.name as NSString).deletingPathExtension
            var name = entry.name
            var number = 2
            while taken[entry.parent, default: []].contains(name.lowercased()) {
                name = entry.isFolder || ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
                number += 1
            }
            taken[entry.parent, default: []].insert(name.lowercased())
            entry.name = name
            return entry
        }
    }

    /// A file name that's safe in the Finder: no slashes or colons.
    public static func fileName(_ title: String, ext: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(120))
        return ext.isEmpty ? base : base + "." + ext
    }

    /// A link as a .webloc, which the Finder opens in the browser.
    public static func webloc(for url: String) -> Data {
        let plist: [String: String] = ["URL": url]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }
}

/// A change made in the Finder, for the app to carry out.
public struct FinderRequest: Codable, Equatable {
    public enum Kind: String, Codable {
        case rename, move, delete, newFolder, newFile, replaceContents
    }

    public var id: UUID
    public var kind: Kind
    /// The entry changed (not for new folders and files).
    public var entryID: String?
    public var name: String?
    /// The folder it goes in (moves, new folders and files).
    public var parent: String?
    /// The file with the new contents, inside the request's own folder.
    public var fileName: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, entryID: String? = nil, name: String? = nil, parent: String? = nil,
                fileName: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.entryID = entryID
        self.name = name
        self.parent = parent
        self.fileName = fileName
        self.createdAt = createdAt
    }
}

/// The share's folder in the App Group: the snapshot, the contents, and
/// the requests waiting.
public struct FinderShare {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var contentFolder: URL { root.appendingPathComponent("Content", isDirectory: true) }
    private var requestsFolder: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    private var snapshotFile: URL { root.appendingPathComponent("Snapshot.json") }

    public func snapshot() -> FinderSnapshot {
        guard let data = try? Data(contentsOf: snapshotFile),
              let snapshot = try? Self.decoder.decode(FinderSnapshot.self, from: data) else {
            return FinderSnapshot(version: 0, entries: [])
        }
        return snapshot
    }

    public func write(_ snapshot: FinderSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: snapshotFile, options: .atomic)
    }

    public func contentURL(_ path: String) -> URL {
        contentFolder.appendingPathComponent(path)
    }

    // MARK: - Requests

    public struct Pending {
        public var request: FinderRequest
        public var folder: URL
        public var file: URL? { request.fileName.map { folder.appendingPathComponent($0) } }
    }

    /// Leaves a request, with a copy of `file` if there is one.
    public func add(_ request: FinderRequest, file: URL? = nil) throws {
        let folder = requestsFolder.appendingPathComponent(request.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file, let name = request.fileName {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        }
        try Self.encoder.encode(request).write(to: folder.appendingPathComponent("Request.json"), options: .atomic)
    }

    /// Waiting requests, oldest first.
    public func pending() -> [Pending] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: requestsFolder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("Request.json")),
                  let request = try? Self.decoder.decode(FinderRequest.self, from: data) else { return nil }
            return Pending(request: request, folder: folder)
        }
        .sorted { $0.request.createdAt < $1.request.createdAt }
    }

    public func remove(_ pending: Pending) {
        try? FileManager.default.removeItem(at: pending.folder)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

#if canImport(Darwin)
extension FinderShare {
    /// The share in the App Group named by `StashAppGroup` in the running
    /// app's (or extension's) Info.plist; nil without the App Group.
    public static func forAppGroup() -> FinderShare? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "StashAppGroup") as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return FinderShare(root: container.appendingPathComponent("Finder", isDirectory: true))
    }
}

extension Notification.Name {
    /// Posted in the app when the Finder has asked for a change.
    public static let stashFinderRequestsArrived = Notification.Name("StashFinderRequestsArrived")
}

/// Tells the app the Finder has left requests, as `ShareSignal` does for sharing.
public enum FinderSignal {
    private static let name = "com.jpottsx1.stash.finder" as CFString

    public static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name), nil, nil, true)
    }

    public static func startListening() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { NotificationCenter.default.post(name: .stashFinderRequestsArrived, object: nil) }
            },
            name, nil, .deliverImmediately)
    }
}
#endif
