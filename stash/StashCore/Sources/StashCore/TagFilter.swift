import Foundation

/// Keep It's tag filter: choose a tag to see the items with it, and the
/// other tags those items have; choose another to narrow it further.
public enum TagFilter {
    public struct Related: Equatable {
        public var tag: String
        /// How many of the items shown have it.
        public var count: Int

        public init(tag: String, count: Int) {
            self.tag = tag
            self.count = count
        }
    }

    /// Whether an item with these tags has every chosen one (by `TagName.key`).
    public static func matches(_ tags: [String], chosen: [String]) -> Bool {
        let keys = Set(tags.map(TagName.key))
        return chosen.allSatisfy { keys.contains(TagName.key($0)) }
    }

    /// The tags on the items that have every chosen one, apart from those
    /// chosen: the most used first, then by name.
    public static func related(_ itemTags: [[String]], chosen: [String]) -> [Related] {
        let chosenKeys = Set(chosen.map(TagName.key))
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for tags in itemTags where matches(tags, chosen: chosen) {
            for tag in Set(tags) {
                let key = TagName.key(tag)
                guard !chosenKeys.contains(key) else { continue }
                counts[key, default: 0] += 1
                names[key] = names[key] ?? tag
            }
        }
        return counts.map { Related(tag: names[$0.key]!, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }
}

/// What *Recents* shows, as Keep It's: what was added, looked at or changed lately.
public enum Recents {
    public enum Kind: String, CaseIterable {
        case all, added, viewed, modified
    }

    /// When the item was last touched in the way asked about; nil if never.
    public static func date(_ kind: Kind, created: Date, modified: Date, viewed: Date?) -> Date? {
        switch kind {
        case .added: created
        case .viewed: viewed
        case .modified: modified
        case .all: max(created, modified, viewed ?? .distantPast)
        }
    }

    /// Whether it was touched within `days` of `now`.
    public static func isRecent(_ date: Date?, days: Int, now: Date = .now) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= Double(days) * 86_400
    }
}
