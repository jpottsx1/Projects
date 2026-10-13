import XCTest
@testable import StashCore

final class StashURLTests: XCTestCase {
    private func parse(_ text: String) -> StashURL.Request? { URL(string: text).flatMap(StashURL.parse) }

    func testActions() throws {
        let id = UUID()
        XCTAssertEqual(parse("stash://item?id=\(id.uuidString)")?.action, .item(id))
        XCTAssertEqual(parse("stash://item/\(id.uuidString)")?.action, .item(id))
        XCTAssertEqual(parse("stash://open?title=Shopping%20List")?.action, .title("Shopping List"))
        XCTAssertEqual(parse("stash://new-note?title=Hi&text=Milk%0AEggs")?.action, .newNote(title: "Hi", text: "Milk\nEggs"))
        XCTAssertEqual(parse("stash://save-link?url=https%3A%2F%2Fexample.com")?.action,
                       .saveLink(URL(string: "https://example.com")!, title: nil))
        XCTAssertEqual(parse("stash://search?query=%23work")?.action, .search("#work"))
        XCTAssertEqual(parse("stash://today")?.action, .today)
        XCTAssertNil(parse("stash://add-to-today"))
        XCTAssertNil(parse("stash://delete-everything"))
        XCTAssertNil(parse("https://item?id=\(id.uuidString)"))
    }

    func testCallbacks() throws {
        let request = try XCTUnwrap(parse("stash://x-callback-url/new-note?text=Hi&x-success=drafts%3A%2F%2Fdone"))
        XCTAssertEqual(request.action, .newNote(title: "", text: "Hi"))
        let id = UUID()
        let back = StashURL.callback(try XCTUnwrap(request.success), id: id)
        XCTAssertTrue(back.absoluteString.hasPrefix("drafts://done?id=\(id.uuidString)&link=stash://item?id%3D") ||
                      back.absoluteString.hasPrefix("drafts://done?id=\(id.uuidString)&link=stash://item?id="))
        XCTAssertEqual(StashURL.markdownLink(title: "A [b]", id: id), "[A \\[b\\]](stash://item?id=\(id.uuidString))")
    }

    func testSchedules() {
        let now = Date()
        XCTAssertTrue(RuleSchedule.hourly.isDue(lastRun: nil, now: now))
        XCTAssertTrue(RuleSchedule.hourly.isDue(lastRun: now.addingTimeInterval(-3601), now: now))
        XCTAssertFalse(RuleSchedule.daily.isDue(lastRun: now.addingTimeInterval(-3601), now: now))
        XCTAssertFalse(RuleSchedule.never.isDue(lastRun: nil, now: now))
    }
}

final class ConcordanceTests: XCTestCase {
    func testWords() {
        let words = Concordance.words(in: ["The garden needs water. Water the garden!", "Garden party at 7, 2026"])
        XCTAssertEqual(words.first, Concordance.Word(word: "garden", count: 3, documents: 2))
        XCTAssertEqual(words.first { $0.word == "water" }?.documents, 1)
        XCTAssertNil(words.first { $0.word == "the" })
        XCTAssertNil(words.first { $0.word == "2026" })
        XCTAssertNotNil(Concordance.words(in: ["the the"], keepsCommonWords: true).first { $0.word == "the" })
        let weights = Concordance.weights(words)
        XCTAssertEqual(weights["garden"], 1)
        XCTAssertEqual(weights["party"], 0)
    }
}
