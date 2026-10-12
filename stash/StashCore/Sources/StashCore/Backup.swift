import Foundation

/// What an export holds, written into it as `Stash Backup.json` beside the
/// files themselves. The files alone are readable anywhere -- notes as
/// Markdown, documents as they were -- and this lets Stash restore
/// everything else exactly: ids, categories, links, highlights.
public struct BackupManifest: Codable, Equatable {
    public static let fileName = "Stash Backup.json"
    public static let currentVersion = 1

    public var version: Int = BackupManifest.currentVersion
    public var exportedAt: Date
    public var categories: [Category]
    public var smartFilters: [SmartFilterRecord]
    /// Nil in exports made before rules existed.
    public var rules: [RuleRecord]?
    /// Feed subscriptions; nil in exports made before feeds.
    public var feeds: [FeedRecord]?
    /// The keys locked items are encrypted with, each still under its
    /// password; nil when nothing exported is locked.
    public var vaults: [VaultRecord]?
    public var items: [ItemRecord]

    public init(exportedAt: Date, categories: [Category] = [], smartFilters: [SmartFilterRecord] = [],
                items: [ItemRecord] = []) {
        self.exportedAt = exportedAt
        self.categories = categories
        self.smartFilters = smartFilters
        self.items = items
    }

    public struct Category: Codable, Equatable {
        public var id: UUID
        public var name: String
        public var parent: UUID?

        public init(id: UUID, name: String, parent: UUID?) {
            self.id = id
            self.name = name
            self.parent = parent
        }
    }

    public struct SmartFilterRecord: Codable, Equatable {
        public var id: UUID
        public var name: String
        public var query: String
        public var createdAt: Date

        public init(id: UUID, name: String, query: String, createdAt: Date) {
            self.id = id
            self.name = name
            self.query = query
            self.createdAt = createdAt
        }
    }

    public struct VaultRecord: Codable, Equatable {
        public var id: UUID
        public var salt: Data
        public var rounds: Int
        public var wrappedKey: Data
        public var createdAt: Date

        public init(id: UUID, salt: Data, rounds: Int, wrappedKey: Data, createdAt: Date) {
            self.id = id
            self.salt = salt
            self.rounds = rounds
            self.wrappedKey = wrappedKey
            self.createdAt = createdAt
        }
    }

    public struct FeedRecord: Codable, Equatable {
        public var id: UUID
        public var title: String
        public var url: String
        public var siteURL: String?
        public var category: UUID?
        /// The posts already seen, so they don't come back after restoring.
        public var seenIDs: String
        public var addedAt: Date

        public init(id: UUID, title: String, url: String, siteURL: String?, category: UUID?, seenIDs: String, addedAt: Date) {
            self.id = id
            self.title = title
            self.url = url
            self.siteURL = siteURL
            self.category = category
            self.seenIDs = seenIDs
            self.addedAt = addedAt
        }
    }

    public struct RuleRecord: Codable, Equatable {
        public var id: UUID
        public var name: String
        public var query: String
        public var isEnabled: Bool
        public var createdAt: Date
        public var category: UUID?
        public var tags: String
        public var label: Int
        public var rating: Int
        public var makesFavorite: Bool
        public var marksRead: Bool
        public var takesOutOfInbox: Bool

        public init(id: UUID, name: String, query: String, isEnabled: Bool, createdAt: Date, category: UUID?,
                    tags: String, label: Int, rating: Int, makesFavorite: Bool, marksRead: Bool, takesOutOfInbox: Bool) {
            self.id = id
            self.name = name
            self.query = query
            self.isEnabled = isEnabled
            self.createdAt = createdAt
            self.category = category
            self.tags = tags
            self.label = label
            self.rating = rating
            self.makesFavorite = makesFavorite
            self.marksRead = marksRead
            self.takesOutOfInbox = takesOutOfInbox
        }
    }

    public struct HighlightRecord: Codable, Equatable {
        public var id: UUID
        public var text: String
        public var note: String
        public var color: String
        public var anchor: String
        public var position: Double
        public var createdAt: Date

        public init(id: UUID, text: String, note: String, color: String, anchor: String,
                    position: Double, createdAt: Date) {
            self.id = id
            self.text = text
            self.note = note
            self.color = color
            self.anchor = anchor
            self.position = position
            self.createdAt = createdAt
        }
    }

    public struct ItemRecord: Codable, Equatable {
        public var id: UUID
        public var kind: String
        public var title: String
        public var body: String = ""
        public var summary: String = ""
        public var url: String?
        public var createdAt: Date
        public var modifiedAt: Date
        public var isFavorite = false
        public var trashedAt: Date?
        public var isUnread = false
        public var inInbox = false
        public var label = 0
        public var rating = 0
        public var category: UUID?
        public var tags: [String] = []
        public var linksTo: [UUID] = []
        public var contentType: String?
        public var contentHash: String = ""
        public var extractedText: String = ""
        public var readingPosition: String = ""
        public var archivedAt: Date?
        /// Where the document's file is inside the export.
        public var file: String?
        /// Where the saved copy of a link's page is inside the export.
        public var pageCopy: String?
        /// The readable Markdown version inside the export.
        public var markdown: String?
        public var highlights: [HighlightRecord] = []
        /// A note's pictures: each one's name, and where it is in the export.
        /// Nil in exports made before notes had pictures.
        public var attachments: [String: String]?
        /// Whether it's a template (nil in exports made before templates).
        public var isTemplate: Bool?
        /// A locked item's encrypted text (`SealedContents`), and the vault
        /// it's encrypted with. Its files in the export are encrypted too.
        public var sealed: Data?
        public var sealedVault: UUID?
        /// The feed it came from, and what the feed called it.
        public var feed: UUID?
        public var feedEntryID: String?

        public init(id: UUID, kind: String, title: String, createdAt: Date, modifiedAt: Date) {
            self.id = id
            self.kind = kind
            self.title = title
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }

    /// "Work/Clients" for a category, from the categories in this manifest.
    public func folder(for category: UUID?) -> String {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        var next = category
        var seen: Set<UUID> = []
        while let id = next, let found = byID[id], seen.insert(id).inserted {
            names.insert(ExportNaming.safe(found.name), at: 0)
            next = found.parent
        }
        return names.joined(separator: "/")
    }
}

/// File names inside an export.
public enum ExportNaming {
    /// A name with nothing a file system objects to: no slashes or colons,
    /// no leading dot, not too long.
    public static func safe(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// `folder/name.ext`, made different from every path already in
    /// `taken` (compared ignoring case, as most file systems do) by adding
    /// " 2", " 3"... and added to it.
    public static func unique(_ name: String, ext: String, in folder: String, taken: inout Set<String>) -> String {
        let base = safe(name)
        let suffix = ext.isEmpty ? "" : "." + ext
        let prefix = folder.isEmpty ? "" : folder + "/"
        var candidate = prefix + base + suffix
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = prefix + base + " \(number)" + suffix
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

/// An item as a Markdown file anyone can read: a block of details at the
/// top (YAML front matter, which most Markdown apps understand), then its
/// text, then its highlights.
public enum ExportMarkdown {
    public static func render(_ item: BackupManifest.ItemRecord, category: String) -> String {
        var lines = ["---"]
        lines.append("title: " + yaml(item.title))
        lines.append("kind: " + item.kind)
        if let url = item.url { lines.append("url: " + yaml(url)) }
        if !category.isEmpty { lines.append("category: " + yaml(category)) }
        if !item.tags.isEmpty { lines.append("tags: [" + item.tags.map(yaml).joined(separator: ", ") + "]") }
        let dates = ISO8601DateFormatter()
        lines.append("created: " + dates.string(from: item.createdAt))
        lines.append("modified: " + dates.string(from: item.modifiedAt))
        if item.isFavorite { lines.append("favorite: true") }
        if let label = ItemLabel(rawValue: item.label), label != .none { lines.append("label: " + label.name.lowercased()) }
        if item.rating > 0 { lines.append("rating: \(item.rating)") }
        if let file = item.file { lines.append("file: " + yaml(file.split(separator: "/").last.map(String.init) ?? file)) }
        lines.append("---")
        lines.append("")

        if !item.summary.isEmpty {
            lines.append("> " + item.summary.replacingOccurrences(of: "\n", with: "\n> "))
            lines.append("")
        }
        if !item.body.isEmpty {
            lines.append(item.body)
            lines.append("")
        }
        let highlights = item.highlights.sorted { $0.position < $1.position }
        if !highlights.isEmpty {
            lines.append("## Highlights")
            lines.append("")
            for highlight in highlights {
                lines.append("> " + highlight.text.replacingOccurrences(of: "\n", with: "\n> "))
                if !highlight.note.isEmpty {
                    lines.append("")
                    lines.append(highlight.note)
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A YAML string, quoted when it has to be.
    static func yaml(_ text: String) -> String {
        let plain = text.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._/-]*$"#, options: .regularExpression) != nil
            && !["true", "false", "yes", "no", "null"].contains(text.lowercased())
        if plain { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
