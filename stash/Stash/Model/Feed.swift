import Foundation
import SwiftData

/// A web feed (RSS, Atom or JSON Feed) Stash checks for new posts, which
/// arrive as links, unread, under the feed in the sidebar.
@Model
final class Feed {
    var uuid: UUID = UUID()
    var title: String = ""
    /// The feed itself, not the site.
    var urlString: String = ""
    var siteURLString: String?
    var addedAt: Date = Date()
    var lastCheckedAt: Date?
    /// Why the last check failed; empty when it worked.
    var lastError: String = ""
    /// The posts already seen, newest first, one per line, so a post that's
    /// been deleted doesn't come back. Kept to the last few hundred.
    var seenIDs: String = ""
    /// Where new posts are filed; nil to leave them unfiled. A category's
    /// uuid rather than a relationship, so deleting one leaves this harmless.
    var categoryID: UUID?
    @Relationship(deleteRule: .nullify, inverse: \Item.feed) var items: [Item]? = []

    init(title: String, url: URL) {
        self.title = title
        self.urlString = url.absoluteString
    }

    var url: URL? { URL(string: urlString) }

    static let seenKept = 500

    var seen: Set<String> { Set(seenIDs.split(separator: "\n").map(String.init)) }

    func markSeen(_ ids: [String]) {
        let old = seenIDs.split(separator: "\n").map(String.init)
        let fresh = ids.filter { !old.contains($0) }
        seenIDs = (fresh + old).prefix(Self.seenKept).joined(separator: "\n")
    }
}
