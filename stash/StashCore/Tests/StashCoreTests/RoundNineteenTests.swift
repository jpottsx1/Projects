import XCTest
@testable import StashCore

final class PDFToolTests: XCTestCase {
    func testPageRanges() {
        XCTAssertEqual(PageRanges.parse("1-3, 5, 8-", pageCount: 10), [1...3, 5...5, 8...10])
        XCTAssertEqual(PageRanges.parse("-2", pageCount: 4), [1...2])
        XCTAssertNil(PageRanges.parse("0-2", pageCount: 4))
        XCTAssertNil(PageRanges.parse("3-1", pageCount: 4))
        XCTAssertNil(PageRanges.parse("5", pageCount: 4))
        XCTAssertNil(PageRanges.parse("two", pageCount: 4))
        XCTAssertEqual(PageRanges.singlePages(3), [1...1, 2...2, 3...3])
        XCTAssertEqual(PageRanges.name("Report", 2...4), "Report, pages 2-4")
    }

    func testImprint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)))
        let imprint = Imprint(text: "{title} – {page} of {pages} – {date}", position: .bottomRight)
        XCTAssertEqual(imprint.text(page: 2, of: 7, title: "Lease", date: date, calendar: calendar), "Lease – 2 of 7 – 2026-03-09")
        let origin = imprint.origin(textWidth: 100, textHeight: 10, pageWidth: 612, pageHeight: 792)
        XCTAssertEqual(origin.x, 612 - 24 - 100)
        XCTAssertEqual(origin.y, 24)
    }
}

final class AliasTests: XCTestCase {
    func testSplitting() {
        XCTAssertEqual(Aliases.split("NYC, New York City;\nnyc\n  "), ["NYC", "New York City"])
    }

    func testAutoLinks() {
        let names = [AutoLink.Name(name: "New York", title: "New York"), AutoLink.Name(name: "New York City", title: "NYC Trip"),
                     AutoLink.Name(name: "Paris", title: "Paris"), AutoLink.Name(name: "Ann", title: "Ann")]
        let text = """
            # Paris plans
            We loved new york city and Paris. Paris again.
            `Paris` in code, [[Paris]] linked, https://paris.example.com/
            """
        let linked = AutoLink.link(text, names: names, scheme: "stash")
        let lines = linked.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# Paris plans")
        XCTAssertEqual(lines[1], "We loved [new york city](stash://open?title=NYC%20Trip) and [Paris](stash://open?title=Paris). Paris again.")
        XCTAssertEqual(lines[2], "`Paris` in code, [[Paris]] linked, https://paris.example.com/")
        // Too short to link.
        XCTAssertEqual(AutoLink.link("Ann said", names: names, scheme: "stash"), "Ann said")
    }
}

final class SheetTests: XCTestCase {
    func testReadingAndWriting() {
        let sheet = Sheet(text: "Name,Notes,Price\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\",3\nBo,,12\n")
        XCTAssertEqual(sheet.rows, [["Name", "Notes", "Price"], ["Smith, J", "said \"hi\"\nthen left", "3"], ["Bo", "", "12"]])
        XCTAssertEqual(Sheet(text: sheet.text), sheet)
        let tabs = Sheet(text: "a\tb\n1\t2", separator: "\t")
        XCTAssertEqual(tabs.rows, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(tabs.text, "a\tb\n1\t2\n")
        XCTAssertEqual(Sheet(text: "a,b,c\n1").rows[1], ["1", "", ""])
    }

    func testChanges() {
        var sheet = Sheet(text: "Item,Price\nPears,12\nApples,3\nFigs,\nBananas,100\n")
        sheet.sort(byColumn: 1, ascending: true)
        XCTAssertEqual(sheet.rows.map { $0[0] }, ["Item", "Apples", "Pears", "Bananas", "Figs"])
        sheet.sort(byColumn: 0, ascending: false)
        XCTAssertEqual(sheet.rows.map { $0[0] }, ["Item", "Pears", "Figs", "Bananas", "Apples"])
        sheet.insertColumn(after: 0, heading: "Kind")
        XCTAssertEqual(sheet.headings, ["Item", "Kind", "Price"])
        sheet.deleteColumn(1)
        sheet.insertRow(after: 0)
        XCTAssertEqual(sheet.rows[1], ["", ""])
        sheet.deleteRow(0)
        XCTAssertEqual(sheet.headings, ["Item", "Price"])
        XCTAssertEqual(Sheet.blank().rows.count, 6)
    }
}
