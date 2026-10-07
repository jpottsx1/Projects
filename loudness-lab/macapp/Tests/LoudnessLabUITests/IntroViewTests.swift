import XCTest
@testable import LoudnessLabUI

/// `LoudnessLabIntroView` takes plain URLs from its host and gives the intro
/// panel the list it already works from.
final class IntroViewTests: XCTestCase {

    func testItemsCarryPathNameAndFolder() throws {
        let items = LoudnessLabIntroView.items(for: [
            URL(fileURLWithPath: "/Music/80s/Song One.mp3"),
        ])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.path, "/Music/80s/Song One.mp3")
        XCTAssertEqual(item.name, "Song One")
        XCTAssertEqual(item.folder, "/Music/80s")
        XCTAssertTrue(item.included)
    }

    func testOrderIsKeptAndRepeatsAreDropped() {
        let a = URL(fileURLWithPath: "/m/a.mp3"), b = URL(fileURLWithPath: "/m/b.mp3")
        let items = LoudnessLabIntroView.items(for: [b, a, b])
        XCTAssertEqual(items.map(\.path), ["/m/b.mp3", "/m/a.mp3"])
    }

    func testNothingGivesAnEmptyList() {
        XCTAssertTrue(LoudnessLabIntroView.items(for: []).isEmpty)
    }
}
