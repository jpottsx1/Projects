import XCTest
@testable import StashCore

final class PicturesAndTablesTests: XCTestCase {
    func testPictureBlocks() {
        XCTAssertEqual(MarkdownBlocks.parse("Before\n![A cat](attachment:cat.png)\nafter"), [
            .paragraph("Before"), .image(alt: "A cat", source: "attachment:cat.png"), .paragraph("after"),
        ])
        // Not alone on its line: left as text.
        XCTAssertEqual(MarkdownBlocks.parse("see ![x](y.png) here"), [.paragraph("see ![x](y.png) here")])
    }

    func testTableBlocks() {
        let text = "| Name | Qty |\n|---|:-:|\n| Apples | 3 |\n| Pears | 12 |\nDone"
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .table(header: ["Name", "Qty"], rows: [["Apples", "3"], ["Pears", "12"]]),
            .paragraph("Done"),
        ])
        // Without a separator line it's just text.
        XCTAssertEqual(MarkdownBlocks.parse("| a | b |"), [.paragraph("| a | b |")])
    }

    func testTidyLinesUpColumns() throws {
        let text = "Intro\n| Name | Qty |\n|---|:-:|\n| Apples | 3 |\n| Pears | 12 |\nEnd"
        let tidied = try XCTUnwrap(MarkdownTable.tidy(text, aroundLine: 3))
        XCTAssertEqual(tidied.lines, 1..<5)
        XCTAssertEqual(tidied.text, """
            Intro
            | Name   | Qty |
            | ------ | :-: |
            | Apples | 3   |
            | Pears  | 12  |
            End
            """)
        XCTAssertNil(MarkdownTable.tidy(text, aroundLine: 0))
    }

    func testTemplateIsATable() {
        XCTAssertEqual(MarkdownBlocks.parse(MarkdownTable.template(columns: 2, rows: 1)),
                       [.table(header: ["Column 1", "Column 2"], rows: [["", ""]])])
    }

    func testHTML() {
        let html = MarkdownHTML.render("![cat](attachment:c.png)\n| a | b |\n|---|---|\n| 1 | **2** |",
                                       picture: { $0 == "attachment:c.png" ? "data:x" : nil })
        XCTAssertEqual(html, """
            <p><img src="data:x" alt="cat"></p>
            <table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td><strong>2</strong></td></tr></tbody></table>
            """)
    }

    func testStylingAndPlainText() {
        let spans = MarkdownStyling.spans(in: "![cat](attachment:c.png)\n| a | b |")
        XCTAssertEqual(spans.map(\.style), [.image(source: "attachment:c.png"), .tableRow])
        XCTAssertEqual(MarkdownStyling.plainText("Hello\n![cat](attachment:c.png)\nthere"), "Hello there")
    }
}

final class OutlineTests: XCTestCase {
    func testHeadingsWithOffsets() {
        let text = "# One\ntext\n```\n# not a heading\n```\n## Two **bold**"
        XCTAssertEqual(MarkdownOutline.headings(in: text), [
            .init(level: 1, title: "One", offset: 0),
            .init(level: 2, title: "Two bold", offset: 35),
        ])
    }
}

final class LinkGraphTests: XCTestCase {
    func testLayoutStaysInsideAndKeepsLinkedItemsClose() {
        // 0-1-2 linked in a chain; 3, 4 and 5 linked to nothing.
        let points = LinkGraph.layout(count: 6, edges: [(0, 1), (1, 2)])
        XCTAssertEqual(points.count, 6)
        for point in points {
            XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y))
        }
        func distance(_ a: Int, _ b: Int) -> Double {
            hypot(points[a].x - points[b].x, points[a].y - points[b].y)
        }
        XCTAssertLessThan(distance(0, 1), distance(0, 4))
        // Same links, same picture.
        XCTAssertEqual(points, LinkGraph.layout(count: 6, edges: [(0, 1), (1, 2)]))
    }

    func testSmallCases() {
        XCTAssertEqual(LinkGraph.layout(count: 0, edges: []), [])
        XCTAssertEqual(LinkGraph.layout(count: 1, edges: []), [.init(x: 0.5, y: 0.5)])
    }
}
