import XCTest
@testable import StashCore

final class TagFilterTests: XCTestCase {
    func testRelatedTags() {
        let items = [["work", "urgent"], ["work", "home"], ["Work", "urgent", "q3"], ["home"]]
        XCTAssertEqual(TagFilter.related(items, chosen: []).first, TagFilter.Related(tag: "work", count: 3))
        let related = TagFilter.related(items, chosen: ["work"])
        XCTAssertEqual(related.map(\.tag), ["urgent", "home", "q3"])
        XCTAssertEqual(related.map(\.count), [2, 1, 1])
        XCTAssertEqual(TagFilter.related(items, chosen: ["work", "urgent"]).map(\.tag), ["q3"])
        XCTAssertTrue(TagFilter.matches(["Work", "urgent"], chosen: ["work"]))
        XCTAssertFalse(TagFilter.matches(["home"], chosen: ["work"]))
    }

    func testRecents() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-30 * 86_400), recent = now.addingTimeInterval(-86_400)
        XCTAssertEqual(Recents.date(.all, created: old, modified: old, viewed: recent), recent)
        XCTAssertNil(Recents.date(.viewed, created: old, modified: old, viewed: nil))
        XCTAssertTrue(Recents.isRecent(recent, days: 7, now: now))
        XCTAssertFalse(Recents.isRecent(old, days: 7, now: now))
    }
}

final class SearchFilterTests: XCTestCase {
    func testSizes() throws {
        let query = SearchQuery("size:>1.5mb report size:<=2gb")
        XCTAssertEqual(query.sizes.map(\.bytes), [1_500_000, 2_000_000_000])
        XCTAssertEqual(query.terms, [.word("report")])
        XCTAssertTrue(query.sizes[0].matches(1_600_000))
        XCTAssertFalse(query.sizes[0].matches(1_500_000))
        XCTAssertEqual(SearchQuery("size:500k").sizes.first?.comparison, .greaterOrEqual)
        XCTAssertTrue(SearchQuery("size:huge").sizes.isEmpty)
    }

    func testDatesAndSources() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let query = SearchQuery("created:2026-03-01 modified:>7d source:Example.com")
        XCTAssertEqual(query.sources, ["example.com"])
        let created = try XCTUnwrap(query.created.first)
        XCTAssertTrue(created.matches(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23))), now: now, calendar: calendar))
        XCTAssertFalse(created.matches(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))), now: now, calendar: calendar))
        let modified = try XCTUnwrap(query.modified.first)
        XCTAssertTrue(modified.matches(now, now: now, calendar: calendar))
        XCTAssertFalse(modified.matches(now.addingTimeInterval(-10 * 86_400), now: now, calendar: calendar))
        XCTAssertFalse(SearchQuery("created:<7d").isEmpty)
    }

    func testFilterSuggestions() {
        let suggest = { SearchSuggestions.suggestions(for: $0, tags: [], categories: [], lists: [], fields: []) }
        XCTAssertEqual(suggest("siz").map(\.completion), ["size: "])
        XCTAssertEqual(suggest("size:>1").map(\.completion), ["size:>1mb ", "size:>10mb "])
        XCTAssertEqual(suggest("created:>").map(\.completion), ["created:>7d ", "created:>1m "])
    }
}
