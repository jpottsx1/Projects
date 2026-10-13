import Foundation

/// How a library has grown and been used, for the statistics: worked out
/// from a light record of each item, so it can be done off the main thread
/// and tested.
public struct LibraryStats: Equatable {
    public struct Record: Equatable, Sendable {
        public var kind: String
        public var created: Date
        /// Words in a note's text (0 for others).
        public var words: Int
        public var tags: [String]
        /// Its top-level category's name, if it has one.
        public var category: String?
        public var highlights: Int
        public var isQueued: Bool
        public var progress: Double
        public var feed: String?

        public init(kind: String, created: Date, words: Int = 0, tags: [String] = [], category: String? = nil,
                    highlights: Int = 0, isQueued: Bool = false, progress: Double = 0, feed: String? = nil) {
            self.kind = kind
            self.created = created
            self.words = words
            self.tags = tags
            self.category = category
            self.highlights = highlights
            self.isQueued = isQueued
            self.progress = progress
            self.feed = feed
        }
    }

    /// How many of each kind were added in a month.
    public struct Month: Equatable, Identifiable {
        public var start: Date
        public var counts: [String: Int]
        /// Words in the notes added that month.
        public var words: Int
        public var id: Date { start }
        public var total: Int { counts.values.reduce(0, +) }
    }

    public struct Count: Equatable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public var total = 0
    public var byKind: [String: Int] = [:]
    public var words = 0
    public var highlights = 0
    /// The last twelve months, oldest first, including empty ones.
    public var months: [Month] = []
    public var topTags: [Count] = []
    public var topCategories: [Count] = []
    public var queued = 0
    /// Queued items read to the end (98% or more).
    public var finished = 0
    /// Posts from each feed in the last 30 days, busiest first.
    public var feedPosts: [Count] = []

    public init() {}

    public init(_ records: [Record], now: Date = Date(), calendar: Calendar = .current, top: Int = 10) {
        total = records.count
        var tagCounts: [String: Int] = [:]
        var categoryCounts: [String: Int] = [:]
        var feedCounts: [String: Int] = [:]
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let firstMonth = calendar.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth
        var monthly: [Date: Month] = [:]
        for offset in 0..<12 {
            guard let start = calendar.date(byAdding: .month, value: offset, to: firstMonth) else { continue }
            monthly[start] = Month(start: start, counts: [:], words: 0)
        }
        for record in records {
            byKind[record.kind, default: 0] += 1
            words += record.words
            highlights += record.highlights
            for tag in record.tags { tagCounts[tag, default: 0] += 1 }
            if let category = record.category { categoryCounts[category, default: 0] += 1 }
            if record.isQueued {
                queued += 1
                if record.progress >= 0.98 { finished += 1 }
            }
            if let feed = record.feed, record.created >= monthAgo { feedCounts[feed, default: 0] += 1 }
            if let start = calendar.dateInterval(of: .month, for: record.created)?.start, monthly[start] != nil {
                monthly[start]?.counts[record.kind, default: 0] += 1
                monthly[start]?.words += record.words
            }
        }
        months = monthly.values.sorted { $0.start < $1.start }
        func ranked(_ counts: [String: Int]) -> [Count] {
            counts.map { Count(name: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
                .prefix(top).map { $0 }
        }
        topTags = ranked(tagCounts)
        topCategories = ranked(categoryCounts)
        feedPosts = ranked(feedCounts)
    }

    /// Words in Markdown text, roughly: runs of letters or digits.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isWordCharacter = CharacterSet.alphanumerics.contains(scalar)
            if isWordCharacter, !inWord { count += 1 }
            inWord = isWordCharacter
        }
        return count
    }
}
