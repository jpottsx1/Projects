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
    /// Who made this change, by name, for "last changed by"; not part of the signature.
    public var editedBy: String?

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

    /// The zone a single shared item goes in, on its own.
    public static func zoneName(forItem id: UUID) -> String { "item-" + id.uuidString }

    public static func itemID(fromZone name: String) -> UUID? {
        guard name.hasPrefix("item-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("item-".count)))
    }

    /// What to send and what to delete, from each item's signature now and as last sent.
    public static func changes(now: [UUID: String], sent: [UUID: String]) -> (save: [UUID], delete: [UUID]) {
        let save = now.filter { sent[$0.key] != $0.value }.keys.sorted { $0.uuidString < $1.uuidString }
        let delete = sent.keys.filter { now[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        return (save, delete)
    }
}

extension SharedItemPayload {
    /// Everything someone can change about the item, and nothing worked out
    /// from it (read text, hashes), so the same item gives the same
    /// signature on every device that has it.
    public var signature: String {
        let highlights = highlights.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { [$0.id.uuidString, $0.text, $0.note, $0.color, $0.customColor].joined(separator: "\u{1}") }
        let fields: [String] = [kind, title, body, url ?? "", summary, String(Int(modifiedAt.timeIntervalSince1970)),
                                tags.sorted().joined(separator: ","), folders.joined(separator: "/"), contentType ?? "",
                                fileName ?? ""] + highlights
        return MD5.hex(Data(fields.joined(separator: "\u{0}").utf8))
    }
}

/// When an item someone else changed arrives: whether to take their change.
public enum SharedMerge {
    public enum Decision: Equatable {
        /// Nothing new: an echo of a change from here, or the same as here.
        case ignore
        /// Theirs replaces what's here.
        case apply
        /// Both changed it; what's here is newer, and goes out in turn.
        case keepLocal
    }

    /// `sent`: the signature last sent from here or taken in here; `local`:
    /// the item's here now (nil if it isn't here).
    public static func decide(incoming: String, incomingModified: Date, sent: String?, local: String?,
                              localModified: Date?) -> Decision {
        if incoming == sent || incoming == local { return .ignore }
        guard let local else { return .apply }
        // Not changed here since: theirs is simply the latest.
        if local == sent || sent == nil { return .apply }
        return (localModified ?? .distantPast) > incomingModified ? .keepLocal : .apply
    }
}
