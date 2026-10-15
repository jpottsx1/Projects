import XCTest
@testable import StashCore

final class ImportsTests: XCTestCase {
    func testPocketCSV() throws {
        let csv = "title,url,time_added,tags,status\nSoup,https://example.com/soup,1700000000,cooking|winter,unread\nBad,notaurl,1,,unread\n"
        let links = try XCTUnwrap(LinkExport.parse(csv: csv))
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].tags, ["cooking", "winter"])
        XCTAssertEqual(links[0].added, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(links[0].folders, [])
    }

    func testInstapaperAndRaindrop() throws {
        let instapaper = "URL,Title,Selection,Folder,Timestamp,Tags\nhttps://a.example,A,Good bit,Recipes,1700000000,\"[\"\"food\"\"]\"\nhttps://b.example,B,,Unread,1700000000,\n"
        let links = try XCTUnwrap(LinkExport.parse(csv: instapaper))
        XCTAssertEqual(links.map(\.folders), [["Recipes"], []])
        XCTAssertEqual(links[0].note, "Good bit")
        XCTAssertEqual(links[0].tags, ["food"])
        let raindrop = "id,title,note,excerpt,url,folder,tags,created\n1,C,mine,theirs,https://c.example,Work/Reading,\"x, y\",2026-01-02T03:04:05.000Z\n"
        let drop = try XCTUnwrap(LinkExport.parse(csv: raindrop)?.first)
        XCTAssertEqual(drop.folders, ["Work", "Reading"])
        XCTAssertEqual(drop.tags, ["x", "y"])
        XCTAssertEqual(drop.note, "mine\n\ntheirs")
        XCTAssertNotNil(drop.added)
        XCTAssertNil(LinkExport.parse(csv: "name,price\nA,1\n"))
    }

    func testPocketHTML() {
        let html = #"<ul><li><a href="https://example.com/x" time_added="1700000000" tags="a,b">X</a></li></ul>"#
        XCTAssertEqual(BookmarksFile.parse(html).first?.added, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOPML() {
        let xml = """
            <?xml version="1.0"?><opml version="2.0"><head><title>Mine</title></head><body>
            <outline text="Tech"><outline type="rss" text="Blog" xmlUrl="https://blog.example/feed"/></outline>
            <outline type="rss" title="News" xmlUrl="https://news.example/rss"/>
            </body></opml>
            """
        let feeds = OPML.parse(Data(xml.utf8))
        XCTAssertEqual(feeds, [OPML.Feed(title: "Blog", url: "https://blog.example/feed", folders: ["Tech"]),
                               OPML.Feed(title: "News", url: "https://news.example/rss")])
        XCTAssertEqual(OPML.parse(Data(OPML.write(feeds).utf8)), feeds)
    }

    func testTextBundles() {
        XCTAssertEqual(MarkdownImport.textBundle("Bear/Recipes/Soup.textbundle/text.markdown")?.name, "Soup")
        XCTAssertEqual(MarkdownImport.textBundle("Bear/Recipes/Soup.textbundle/text.markdown")?.folder, "Bear/Recipes")
        XCTAssertNil(MarkdownImport.textBundle("Bear/Soup.textbundle/assets/pic.png"))
        XCTAssertNil(MarkdownImport.textBundle("Notes/text.md"))
        XCTAssertTrue(MarkdownImport.isTextBundleExtra("A.textbundle/info.json"))
    }
}
