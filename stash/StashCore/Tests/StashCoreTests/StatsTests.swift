import XCTest
@testable import StashCore

final class LibraryStatsTests: XCTestCase {
    func testCounts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let lastMonth = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!
        let longAgo = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let records = [
            LibraryStats.Record(kind: "note", created: now, words: 120, tags: ["work", "ideas"], category: "Work"),
            LibraryStats.Record(kind: "note", created: lastMonth, words: 30, tags: ["work"]),
            LibraryStats.Record(kind: "link", created: now, highlights: 3, isQueued: true, progress: 1, feed: "Blog"),
            LibraryStats.Record(kind: "link", created: longAgo, isQueued: true, progress: 0.4, feed: "Blog"),
        ]
        let stats = LibraryStats(records, now: now, calendar: calendar)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.byKind, ["note": 2, "link": 2])
        XCTAssertEqual(stats.words, 150)
        XCTAssertEqual(stats.highlights, 3)
        XCTAssertEqual(stats.months.count, 12)
        XCTAssertEqual(stats.months.last?.counts, ["note": 1, "link": 1])
        XCTAssertEqual(stats.months.last?.words, 120)
        XCTAssertEqual(stats.months[10].total, 1)
        XCTAssertEqual(stats.topTags.first, .init(name: "work", count: 2))
        XCTAssertEqual(stats.topCategories, [.init(name: "Work", count: 1)])
        XCTAssertEqual(stats.queued, 2)
        XCTAssertEqual(stats.finished, 1)
        // Only the last 30 days' posts.
        XCTAssertEqual(stats.feedPosts, [.init(name: "Blog", count: 1)])
    }

    func testWordCount() {
        XCTAssertEqual(LibraryStats.wordCount("# Plan\n\n- **Buy** milk, eggs & 2 loaves"), 6)
        XCTAssertEqual(LibraryStats.wordCount(""), 0)
    }
}
