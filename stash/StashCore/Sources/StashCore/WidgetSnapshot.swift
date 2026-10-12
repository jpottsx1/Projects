import Foundation

/// What the widgets show, written by the app into the App Group for them
/// to read: widgets can't open the library itself.
public struct WidgetSnapshot: Codable, Equatable {
    public struct Entry: Codable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        /// "note", "link" or "document".
        public var kind: String
        public var subtitle: String
        /// When it's due, for reminders.
        public var date: Date?

        public init(id: UUID, title: String, kind: String, subtitle: String, date: Date? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.subtitle = subtitle
            self.date = date
        }
    }

    public var updatedAt: Date
    public var recent: [Entry]
    public var favorites: [Entry]
    /// Items with a reminder, soonest first.
    public var reminders: [Entry]
    public var inboxCount: Int

    public init(updatedAt: Date, recent: [Entry] = [], favorites: [Entry] = [], reminders: [Entry] = [], inboxCount: Int = 0) {
        self.updatedAt = updatedAt
        self.recent = recent
        self.favorites = favorites
        self.reminders = reminders
        self.inboxCount = inboxCount
    }

    public static let fileName = "Widgets.json"

    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from folder: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// The App Group folder, from the `StashAppGroup` key in the Info.plist;
    /// nil when there's no App Group (sharing and widgets are off).
    public static func folder() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "StashAppGroup") as? String,
              !group.isEmpty, !group.hasPrefix("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// Links the widgets open: `stash://item?id=…`, `stash://new-note`.
    public static func itemURL(_ id: UUID) -> URL { URL(string: "stash://item?id=\(id.uuidString)")! }
    public static let newNoteURL = URL(string: "stash://new-note")!
}
