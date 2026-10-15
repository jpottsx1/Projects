import XCTest
@testable import StashCore

final class StudyMapTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private var cards: [StudyMap.Card] {
        [StudyMap.Card(id: a, parent: nil, order: 1, title: "Soil"),
         StudyMap.Card(id: b, parent: a, order: 0, title: "", excerpt: "Compost feeds the microbes."),
         StudyMap.Card(id: c, parent: nil, order: 0, title: "Water"),
         StudyMap.Card(id: d, parent: UUID(), order: 2, title: "Orphan")]
    }

    func testTree() {
        XCTAssertEqual(StudyMap.children(of: nil, in: cards).map(\.id), [c, a, d])
        XCTAssertEqual(StudyMap.flattened(cards).map(\.depth), [0, 0, 1, 0])
        let (map, paths) = StudyMap.mindMap(cards, title: "Notebook")
        XCTAssertEqual(map.root.children.map(\.title), ["Water", "Soil", "Orphan"])
        XCTAssertEqual(map.root.children[1].children.first?.title, "Compost feeds the microbes.")
        XCTAssertEqual(paths[[1, 0]], b)
    }

    func testMovesAndOutline() {
        XCTAssertFalse(StudyMap.canMove(a, under: b, in: cards))
        XCTAssertFalse(StudyMap.canMove(a, under: a, in: cards))
        XCTAssertTrue(StudyMap.canMove(b, under: c, in: cards))
        XCTAssertTrue(StudyMap.canMove(b, under: nil, in: cards))
        let outline = StudyMap.outline(cards, title: "Notebook").components(separatedBy: "\n")
        XCTAssertEqual(outline[0], "# Notebook")
        XCTAssertEqual(outline[3], "- **Soil**")
        XCTAssertEqual(outline[4], "  - “Compost feeds the microbes.”")
    }

    func testTitleLinks() {
        let pages = ["Compost and soil.", "Nothing here.", "SOIL microbes; subsoil is different.", "ab ab"]
        let matches = TitleLinks.find(["Soil", "soil", "microbes", "ab", "missing"], in: pages)
        XCTAssertEqual(matches, [TitleLinks.Match(title: "Soil", pages: [0, 2]), TitleLinks.Match(title: "microbes", pages: [2])])
    }
}
