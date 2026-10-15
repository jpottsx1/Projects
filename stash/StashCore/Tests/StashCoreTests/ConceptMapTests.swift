import XCTest
@testable import StashCore

final class ConceptMapTests: XCTestCase {
    func testConceptsAndDocuments() {
        let a = UUID(), b = UUID(), c = UUID()
        let highlights = [
            ConceptMap.Highlight(id: UUID(), documentID: a, documentTitle: "Soil", text: "Compost feeds the soil microbes."),
            ConceptMap.Highlight(id: UUID(), documentID: b, documentTitle: "Gardens", text: "Microbes need air and water."),
            ConceptMap.Highlight(id: UUID(), documentID: c, documentTitle: "Bread", text: "Sourdough starters are microbes too."),
            ConceptMap.Highlight(id: UUID(), documentID: a, documentTitle: "Soil", text: "Watering deeply beats watering often."),
            ConceptMap.Highlight(id: UUID(), documentID: b, documentTitle: "Gardens", text: "Mulch keeps watering down."),
            ConceptMap.Highlight(id: UUID(), documentID: c, documentTitle: "Bread", text: "Knead for ten minutes."),
        ]
        let map = ConceptMap.build(highlights)
        XCTAssertEqual(map.concepts.map(\.name), ["microbes", "watering"])
        XCTAssertEqual(map.concepts[0].documents, [a, b, c])
        XCTAssertEqual(map.unsorted, [highlights[5].id])
        let links = map.documentLinks
        XCTAssertEqual(links.first?.concepts.sorted(), ["microbes", "watering"])
        XCTAssertEqual(Set([links.first!.first, links.first!.second]), [a, b])

        let outline = map.outline(title: "Highlights", highlights: highlights)
        let lines = outline.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- Highlights")
        XCTAssertEqual(lines[1], "  - Microbes")
        XCTAssertEqual(lines[2], "    - [[Soil]]")
        XCTAssertEqual(lines[3], "      - “Compost feeds the soil microbes.”")
        XCTAssertTrue(lines.contains("  - Other Highlights"))
        // A mind map reads it back as the same tree.
        XCTAssertEqual(MindMap(markdown: outline).root.children.count, 3)
    }

    func testStems() {
        XCTAssertEqual(ConceptMap.stem("theories"), "theory")
        XCTAssertEqual(ConceptMap.stem("microbes"), "microbe")
        XCTAssertEqual(ConceptMap.stem("glass"), "glass")
        XCTAssertEqual(ConceptMap.stem("status"), "status")
    }
}
