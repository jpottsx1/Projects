import XCTest
@testable import StashCore

final class MindMapTests: XCTestCase {
    private let text = "- Trip\n  - Places\n    - Rome\n    - Venice\n  - Packing\n- Budget"

    func testReadingAndWriting() {
        let map = MindMap(markdown: text)
        XCTAssertEqual(map.root.title, "Trip")
        XCTAssertEqual(map.root.children.map(\.title), ["Places", "Packing", "Budget"])
        XCTAssertEqual(map.node(at: [0, 1])?.title, "Venice")
        XCTAssertEqual(MindMap(markdown: map.markdown), map)
        XCTAssertEqual(MindMap(markdown: "Just text").root.title, "Central Idea")
    }

    func testChanges() {
        var map = MindMap(markdown: text)
        let new = map.addChild(to: [0], title: "Florence")
        XCTAssertEqual(new, [0, 2])
        XCTAssertEqual(map.addSibling(after: [1], title: "Food"), [2])
        XCTAssertEqual(map.root.children.map(\.title), ["Places", "Packing", "Food", "Budget"])
        map.rename([2], to: "Eating")
        XCTAssertEqual(map.node(at: [2])?.title, "Eating")
        map.delete([1])
        XCTAssertEqual(map.root.children.map(\.title), ["Places", "Eating", "Budget"])
        // Venice moves under Budget; a branch can't go inside itself.
        XCTAssertEqual(map.move([0, 1], under: [2]), [2, 0])
        XCTAssertEqual(map.node(at: [2, 0])?.title, "Venice")
        XCTAssertNil(map.move([0], under: [0, 0]))
        map.delete([])
        XCTAssertEqual(map.root.title, "Trip")
    }

    func testLayout() {
        let placed = MindMap(markdown: text).layout()
        XCTAssertEqual(placed.count, 7)
        let rome = placed.first { $0.title == "Rome" }!, venice = placed.first { $0.title == "Venice" }!
        let places = placed.first { $0.title == "Places" }!
        XCTAssertEqual(rome.column, 2)
        XCTAssertEqual(places.row, (rome.row + venice.row) / 2)
        XCTAssertEqual(places.parent, [])
        XCTAssertEqual(placed.first?.path, [])
    }
}
