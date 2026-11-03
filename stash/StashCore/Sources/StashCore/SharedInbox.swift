import Foundation

/// Something saved from another app's share menu, waiting for Stash to
/// open and take it in.
public struct SharedEntry: Codable, Equatable {
    public enum Kind: String, Codable {
        case link, note, file
        /// A picture on a web page (`url`), to save at its biggest; `pageURL` the page.
        case image
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var url: String?
    /// The note's text, or the comment typed alongside a link or file.
    public var text: String
    /// The attached file's name, inside the entry's folder.
    public var fileName: String?
    public var tags: [String]
    /// `ItemCategory.uuid`, chosen from the list the app publishes.
    public var categoryID: UUID?
    /// A category to make and file it in, as a path ("Work › Clients"),
    /// when none of the existing ones would do. Nil from older extensions.
    public var newCategory: String?
    /// A link to keep as something else besides (a `PageFormat`'s raw
    /// value); nil to keep just the link.
    public var saveAs: String?
    /// For a picture: the page it was on.
    public var pageURL: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, title: String, url: String? = nil, text: String = "",
                fileName: String? = nil, tags: [String] = [], categoryID: UUID? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.text = text
        self.fileName = fileName
        self.tags = tags
        self.categoryID = categoryID
        self.createdAt = createdAt
    }
}

/// DEVONthink's clip formats: a web page kept as a PDF, a Markdown note,
/// or a web archive document, besides the link.
public enum PageFormat: String, Codable, CaseIterable, Identifiable {
    case link, pdf, markdown, webArchive

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .link: "Link Only"
        case .pdf: "PDF"
        case .markdown: "Markdown Note"
        case .webArchive: "Web Archive"
        }
    }
}

/// A category as the share sheet sees it: the app writes the list out,
/// since the share extension can't open the library itself.
public struct SharedCategory: Codable, Equatable, Identifiable {
    public var id: UUID
    /// "Work › Clients"
    public var path: String

    public init(id: UUID, path: String) {
        self.id = id
        self.path = path
    }
}

/// The folder the share extension and the app both reach (their App Group
/// container). Each shared thing gets a folder of its own:
///
///     Inbox/<id>/entry.json
///     Inbox/<id>/<the file, if there is one>
///
/// `entry.json` is written last, so the app never picks up an entry whose
/// file is still being copied in.
public struct SharedInbox {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    private var categoriesFile: URL { root.appendingPathComponent("categories.json") }

    public struct Pending {
        public var entry: SharedEntry
        public var folder: URL

        /// The attached file, if it's there.
        public var file: URL? {
            guard let name = entry.fileName else { return nil }
            let url = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Adds an entry, copying `file` in beside it.
    public func add(_ entry: SharedEntry, file: URL? = nil) throws {
        var entry = entry
        let folder = inbox.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file {
            let name = file.lastPathComponent
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
            entry.fileName = name
        }
        try Self.encoder.encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
    }

    /// Everything waiting, oldest first.
    public func pending() -> [Pending] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("entry.json")),
                  let entry = try? Self.decoder.decode(SharedEntry.self, from: data) else { return nil }
            return Pending(entry: entry, folder: folder)
        }
        .sorted { $0.entry.createdAt < $1.entry.createdAt }
    }

    public func remove(_ pending: Pending) {
        try? FileManager.default.removeItem(at: pending.folder)
    }

    public func writeCategories(_ categories: [SharedCategory]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Self.encoder.encode(categories).write(to: categoriesFile, options: .atomic)
    }

    public func categories() -> [SharedCategory] {
        guard let data = try? Data(contentsOf: categoriesFile) else { return [] }
        return (try? Self.decoder.decode([SharedCategory].self, from: data)) ?? []
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
extension SharedInbox {
    /// The inbox in the App Group named by `StashAppGroup` in the running
    /// app's (or extension's) Info.plist. Callers only ask when sharing is
    /// turned on: without the App Group entitlement the folder can't be
    /// reached, and on the Mac asking can raise a privacy prompt.
    public static func forAppGroup() -> SharedInbox? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "StashAppGroup") as? String,
              !group.isEmpty,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return SharedInbox(root: root)
    }
}

extension Notification.Name {
    /// Posted in the app when the share extension has just added something.
    public static let stashSharedItemsArrived = Notification.Name("StashSharedItemsArrived")
}

/// Lets the share extension tell a running copy of the app that something
/// has arrived, so it's taken in at once rather than at the next launch.
/// A system-wide (Darwin) notification, the one kind both can see.
public enum ShareSignal {
    private static let name = "com.jpottsx1.stash.shared" as CFString

    public static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name), nil, nil, true)
    }

    /// Re-posts each signal as `.stashSharedItemsArrived` in this process.
    public static func startListening() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .stashSharedItemsArrived, object: nil)
                }
            },
            name, nil, .deliverImmediately)
    }
}
#endif
