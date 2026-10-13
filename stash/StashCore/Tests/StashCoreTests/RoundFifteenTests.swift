import XCTest
@testable import StashCore

final class QuickOpenTests: XCTestCase {
    func testMatchingAndRanking() {
        XCTAssertNotNil(QuickOpen.score("grc", "Groceries"))
        XCTAssertNil(QuickOpen.score("xyz", "Groceries"))
        XCTAssertNotNil(QuickOpen.score("", "Anything"))
        let names = ["Meeting notes", "Groceries", "Group plans", "Garden"]
        XCTAssertEqual(QuickOpen.rank(names, query: "gro", name: { $0 }).first, "Groceries")
        // Starts of words count: "mn" finds Meeting notes before anything else.
        XCTAssertEqual(QuickOpen.rank(names, query: "mn", name: { $0 }).first, "Meeting notes")
    }
}

final class SearchSuggestionTests: XCTestCase {
    private func suggest(_ text: String) -> [SearchSuggestions.Suggestion] {
        SearchSuggestions.suggestions(for: text, tags: ["work", "weekend"], categories: ["Work Projects", "Home"],
                                      lists: ["Reading"], fields: ["Due date"])
    }

    func testSuggestions() {
        XCTAssertEqual(suggest("lunch #we").map(\.completion), ["lunch #weekend "])
        XCTAssertEqual(suggest("in:wo").map(\.completion), ["in:\"Work Projects\" "])
        XCTAssertEqual(suggest("is:ch").map(\.completion), ["is:checklist "])
        XCTAssertEqual(suggest("wor").map(\.title), ["#work", "in:Work Projects"])
        XCTAssertEqual(suggest("du").map(\.completion), ["Due_date: "])
        XCTAssertTrue(suggest("done ").isEmpty)
    }

    func testChecklistAndHighlightFlags() {
        XCTAssertEqual(SearchQuery("is:checklist is:highlighted").flags, [.checklist, .highlighted])
    }
}

final class TableAndListEditingTests: XCTestCase {
    private let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"

    func testRowsAndColumns() throws {
        let added = try XCTUnwrap(MarkdownTable.change(table, line: 2, column: 0, .addRowBelow))
        XCTAssertEqual(added.components(separatedBy: "\n").count, 4)
        let fromHeader = try XCTUnwrap(MarkdownTable.change(table, line: 0, column: 0, .addRowBelow))
        XCTAssertEqual(fromHeader.components(separatedBy: "\n")[1].filter { $0 == "-" }.count >= 6, true)
        XCTAssertNil(MarkdownTable.change(table, line: 0, column: 0, .deleteRow))
        let deleted = try XCTUnwrap(MarkdownTable.change(table, line: 2, column: 0, .deleteRow))
        XCTAssertEqual(deleted.components(separatedBy: "\n").count, 2)
        let column = try XCTUnwrap(MarkdownTable.change(table, line: 2, column: 0, .addColumnAfter))
        XCTAssertEqual(column.components(separatedBy: "\n")[0].filter { $0 == "|" }.count, 4)
        let fewer = try XCTUnwrap(MarkdownTable.change(table, line: 2, column: 1, .deleteColumn))
        XCTAssertEqual(fewer.components(separatedBy: "\n")[2], "| 1   |")
        XCTAssertEqual(MarkdownTable.column(at: 7, in: "| 1 | 2 |"), 1)
    }

    func testIndentingLists() {
        let text = "- [ ] one\n- [ ] two\nplain"
        let indented = MarkdownFormatting.indent(text, selection: 10..<12, outward: false)
        XCTAssertEqual(indented.text, "- [ ] one\n  - [ ] two\nplain")
        XCTAssertEqual(MarkdownFormatting.indent(indented.text, selection: 12..<12, outward: true).text, text)
        // Not a list line: unchanged.
        XCTAssertEqual(MarkdownFormatting.indent(text, selection: 22..<22, outward: false).text, text)
    }

    func testPictureSizes() {
        XCTAssertEqual(MarkdownBlocks.pictureSize("Cat|300").width, 300)
        XCTAssertEqual(MarkdownBlocks.pictureSize("Cat|300").alt, "Cat")
        XCTAssertNil(MarkdownBlocks.pictureSize("Cat").width)
        XCTAssertEqual(MarkdownBlocks.settingPictureWidth("![Cat](attachment:a.png)", to: 200), "![Cat|200](attachment:a.png)")
        XCTAssertEqual(MarkdownBlocks.settingPictureWidth("![Cat|200](attachment:a.png)", to: nil), "![Cat](attachment:a.png)")
    }
}

final class BookmarksFileTests: XCTestCase {
    func testNetscapeBookmarks() {
        let html = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <DL><p>
              <DT><H3>Recipes</H3>
              <DL><p>
                <DT><A HREF="https://example.com/bread" ADD_DATE="1700000000" TAGS="baking,bread">Bread &amp; Butter</A>
                <DT><H3>Soups</H3>
                <DL><p>
                  <DT><A HREF="https://example.com/soup" ADD_DATE="1700000000000000">Soup</A>
                </DL><p>
              </DL><p>
              <DT><A HREF="https://example.org/">Top</A>
              <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
            </DL>
            """
        let bookmarks = BookmarksFile.parse(html)
        XCTAssertEqual(bookmarks.map(\.title), ["Bread & Butter", "Soup", "Top"])
        XCTAssertEqual(bookmarks.map(\.folders), [["Recipes"], ["Recipes", "Soups"], []])
        XCTAssertEqual(bookmarks[0].tags, ["baking", "bread"])
        XCTAssertEqual(bookmarks[0].added, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(bookmarks[1].added, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(bookmarks[2].added)
    }
}
