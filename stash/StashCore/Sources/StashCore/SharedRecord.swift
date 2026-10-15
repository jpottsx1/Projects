import Foundation

/// An item as it's shared with other people through iCloud: everything
/// that travels about it except its file (sent beside it). One record per
/// item, named by the item's uuid, in a zone per shared category; the
/// recipient's Stash makes the same item (same uuid) from it.
public struct SharedItemPayload: Codable, Equatable {
    public struct Highlight: Codable, Equatable {
        public var id: UUID
        public var text: String
        public var note: String
        public var color: String
        public var customColor: String
        public var anchor: String
        public var position: Double
        public var createdAt: Date

        public init(id: UUID, text: String, note: String, color: String, customColor: String, anchor: String,
                    position: Double, createdAt: Date) {
            self.id = id
            self.text = text
            self.note = note
            self.color = color
            self.customColor = customColor
            self.anchor = anchor
            self.position = position
            self.createdAt = createdAt
        }
    }

    public var kind: String
    public var title: String
    public var body: String
    public var url: String?
    public var summary: String
    /// Text read from the document or page, for search; capped.
    public var extractedText: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var tags: [String]
    /// The categories inside the shared one it's in, outermost first.
    public var folders: [String]
    public var contentType: String?
    /// The file's name, when one is sent beside it.
    public var fileName: String?
    public var highlights: [Highlight]

    public static let textLimit = 200_000

    public init(kind: String, title: String, body: String = "", url: String? = nil, summary: String = "",
                extractedText: String = "", createdAt: Date, modifiedAt: Date, tags: [String] = [], folders: [String] = [],
                contentType: String? = nil, fileName: String? = nil, highlights: [Highlight] = []) {
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.summary = summary
        self.extractedText = String(extractedText.prefix(Self.textLimit))
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tags = tags
        self.folders = folders
        self.contentType = contentType
        self.fileName = fileName
        self.highlights = highlights
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SharedItemPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharedItemPayload.self, from: data)
    }
}

/// Names for shared zones and what's been sent, for deciding what to send next.
public enum SharedZones {
    /// The zone a shared category's items go in.
    public static func zoneName(forCategory id: UUID) -> String { "category-" + id.uuidString }

    public static func categoryID(fromZone name: String) -> UUID? {
        guard name.hasPrefix("category-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("category-".count)))
    }

    /// What to send and what to delete, from each item's signature now and as last sent.
    public static func changes(now: [UUID: String], sent: [UUID: String]) -> (save: [UUID], delete: [UUID]) {
        let save = now.filter { sent[$0.key] != $0.value }.keys.sorted { $0.uuidString < $1.uuidString }
        let delete = sent.keys.filter { now[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        return (save, delete)
    }
}
