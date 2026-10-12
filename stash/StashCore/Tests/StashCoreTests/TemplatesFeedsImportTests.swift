import XCTest
@testable import StashCore

final class TemplateTests: XCTestCase {
    private var values: NoteTemplate.Values {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Monday 12 October 2026, 14:05 UTC.
        let date = Date(timeIntervalSince1970: 1_791_813_900)
        return NoteTemplate.Values(date: date, title: "Standup", clipboard: "copied",
                                   calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    func testPlaceholders() {
        let text = "# {{title}} on {{weekday}}\nDate: {{date}} at {{time}}\n[[{{yesterday}}]] · [[{{ Tomorrow }}]]\n> {{clipboard}}"
        XCTAssertEqual(NoteTemplate.fill(text, with: values), """
            # Standup on Monday
            Date: 2026-10-12 at 14:05
            [[2026-10-11]] · [[2026-10-13]]
            > copied
            """)
    }

    func testCustomFormatsAndUnknownNames() {
        XCTAssertEqual(NoteTemplate.fill("{{date:d MMMM yyyy}} {{time:h a}}", with: values), "12 October 2026 2 PM")
        // Not ours: left alone.
        XCTAssertEqual(NoteTemplate.fill("{{name}} and {{ }} and {single}", with: values), "{{name}} and {{ }} and {single}")
        XCTAssertTrue(NoteTemplate.hasPlaceholders("Hi {{date}}"))
        XCTAssertFalse(NoteTemplate.hasPlaceholders("Hi {date}"))
    }
}

final class FeedTests: XCTestCase {
    func testRSS() throws {
        let rss = """
            <?xml version="1.0"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
            <channel>
              <title>Daring &amp; Bold</title>
              <link>https://example.com/</link>
              <item>
                <title>First post</title>
                <link>/2026/first</link>
                <guid isPermaLink="false">post-1</guid>
                <description>&lt;p&gt;A &lt;b&gt;short&lt;/b&gt; summary.&lt;/p&gt;</description>
                <content:encoded><![CDATA[<p>The whole <em>post</em>.</p>]]></content:encoded>
                <pubDate>Mon, 12 Oct 2026 08:30:00 +0000</pubDate>
              </item>
              <item>
                <title>No guid</title>
                <link>https://example.com/2026/second</link>
              </item>
            </channel>
            </rss>
            """
        let feed = try XCTUnwrap(FeedParser.parse(Data(rss.utf8), from: URL(string: "https://example.com/feed.xml")))
        XCTAssertEqual(feed.title, "Daring & Bold")
        XCTAssertEqual(feed.siteURL?.absoluteString, "https://example.com/")
        XCTAssertEqual(feed.entries.count, 2)
        let first = feed.entries[0]
        XCTAssertEqual(first.id, "post-1")
        XCTAssertEqual(first.link?.absoluteString, "https://example.com/2026/first")
        XCTAssertEqual(first.summary, "A short summary.")
        XCTAssertEqual(first.html, "<p>The whole <em>post</em>.</p>")
        XCTAssertEqual(first.published, Date(timeIntervalSince1970: 1_791_793_800))
        XCTAssertEqual(feed.entries[1].id, "https://example.com/2026/second")
    }

    func testAtom() throws {
        let atom = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title type="text">An Atom Feed</title>
              <link rel="self" href="https://blog.example.org/atom.xml"/>
              <link rel="alternate" href="https://blog.example.org/"/>
              <entry>
                <id>tag:blog.example.org,2026:1</id>
                <title>Hello</title>
                <link rel="alternate" href="https://blog.example.org/hello"/>
                <updated>2026-10-12T08:30:00.000Z</updated>
                <summary>Just saying hello.</summary>
              </entry>
            </feed>
            """
        let feed = try XCTUnwrap(FeedParser.parse(Data(atom.utf8)))
        XCTAssertEqual(feed.title, "An Atom Feed")
        XCTAssertEqual(feed.siteURL?.absoluteString, "https://blog.example.org/")
        XCTAssertEqual(feed.entries.first?.id, "tag:blog.example.org,2026:1")
        XCTAssertEqual(feed.entries.first?.link?.absoluteString, "https://blog.example.org/hello")
        XCTAssertEqual(feed.entries.first?.summary, "Just saying hello.")
        XCTAssertEqual(feed.entries.first?.published, Date(timeIntervalSince1970: 1_791_793_800))
    }

    func testJSONFeed() throws {
        let json = """
            {"version": "https://jsonfeed.org/version/1.1", "title": "JSON Things",
             "home_page_url": "https://json.example.net/",
             "items": [{"id": "1", "url": "https://json.example.net/1", "title": "One",
                        "content_text": "Plain <text>", "date_published": "2026-10-12T08:30:00Z"}]}
            """
        let feed = try XCTUnwrap(FeedParser.parse(Data(json.utf8)))
        XCTAssertEqual(feed.title, "JSON Things")
        XCTAssertEqual(feed.entries.first?.summary, "Plain <text>")
        XCTAssertEqual(feed.entries.first?.html, "Plain &lt;text&gt;")
    }

    func testNotAFeed() {
        XCTAssertNil(FeedParser.parse(Data("<html><body>Hi</body></html>".utf8)))
        XCTAssertNil(FeedParser.parse(Data("{\"name\": 1}".utf8)))
    }

    func testFindingFeedsInAPage() {
        let html = """
            <head>
            <link rel="stylesheet" href="/style.css">
            <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
            <link type="application/atom+xml" rel="alternate" href="https://example.com/atom?a=1&amp;b=2">
            </head>
            """
        XCTAssertEqual(FeedParser.feedLinks(inHTML: html, base: URL(string: "https://example.com/blog/")).map(\.absoluteString),
                       ["https://example.com/feed.xml", "https://example.com/atom?a=1&b=2"])
    }

    func testDates() {
        let expected = Date(timeIntervalSince1970: 1_791_793_800)
        XCTAssertEqual(FeedParser.date("Mon, 12 Oct 2026 08:30:00 GMT"), expected)
        XCTAssertEqual(FeedParser.date("12 Oct 2026 10:30:00 +0200"), expected)
        XCTAssertEqual(FeedParser.date("2026-10-12T04:30:00-04:00"), expected)
        XCTAssertNil(FeedParser.date("someday"))
    }
}

final class FolderIndexTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_000_000)
    private let day2 = Date(timeIntervalSince1970: 2_000_000)

    func testAddedChangedRemoved() {
        let a = UUID(), b = UUID(), c = UUID()
        let changes = FolderIndex.changes(
            onDisk: [.init(path: "a.pdf", size: 10, modified: day1),
                     .init(path: "b.txt", size: 20, modified: day2),
                     .init(path: "new/d.png", size: 40, modified: day2)],
            known: [.init(id: a, file: .init(path: "a.pdf", size: 10, modified: day1.addingTimeInterval(0.4))),
                    .init(id: b, file: .init(path: "b.txt", size: 20, modified: day1)),
                    .init(id: c, file: .init(path: "c.doc", size: 30, modified: day1))])
        XCTAssertEqual(changes.added.map(\.path), ["new/d.png"])
        XCTAssertEqual(changes.changed.map(\.id), [b])
        XCTAssertEqual(changes.removed, [c])
        XCTAssertTrue(changes.moved.isEmpty)
    }

    func testMovesKeepTheirItem() {
        let a = UUID(), b = UUID()
        let changes = FolderIndex.changes(
            onDisk: [.init(path: "Taxes/2025.pdf", size: 10, modified: day1),
                     .init(path: "renamed.txt", size: 20, modified: day2)],
            known: [.init(id: a, file: .init(path: "2025.pdf", size: 10, modified: day1)),
                    .init(id: b, file: .init(path: "notes.txt", size: 20, modified: day2))])
        XCTAssertEqual(changes.moved.map(\.id), [a, b])
        XCTAssertEqual(changes.moved.map(\.file.path), ["Taxes/2025.pdf", "renamed.txt"])
        XCTAssertTrue(changes.added.isEmpty)
        XCTAssertTrue(changes.removed.isEmpty)
    }

    func testLookalikesAreNotMoves() {
        // Two new files just like the one that went: can't tell which, so not a move.
        let a = UUID()
        let changes = FolderIndex.changes(
            onDisk: [.init(path: "x.txt", size: 5, modified: day1), .init(path: "y.txt", size: 5, modified: day1)],
            known: [.init(id: a, file: .init(path: "z.txt", size: 5, modified: day1))])
        XCTAssertEqual(changes.added.count, 2)
        XCTAssertEqual(changes.removed, [a])
    }

    func testFoldersAndIgnoredFiles() {
        XCTAssertEqual(FolderIndex.folders(of: "a/b/c.pdf"), ["a", "b"])
        XCTAssertEqual(FolderIndex.folders(of: "c.pdf"), [])
        XCTAssertTrue(FolderIndex.isIgnored(".DS_Store"))
        XCTAssertTrue(FolderIndex.isIgnored("~$Report.docx"))
        XCTAssertFalse(FolderIndex.isIgnored("Report.docx"))
    }
}

final class ImportTests: XCTestCase {
    func testMD5() {
        XCTAssertEqual(MD5.hex(Data()), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex(Data("The quick brown fox jumps over the lazy dog".utf8)), "9e107d9d372bb6826bd81d3542a419d6")
        // Longer than one 64-byte block.
        XCTAssertEqual(MD5.hex(Data(String(repeating: "a", count: 100).utf8)), "36a92cc94a9e0fa21f625f8bfb007adf")
    }

    func testHTMLToMarkdown() {
        let html = """
            <h1>Title</h1>
            <p>Some <b>bold</b>, <em>italic </em>and <a href="https://example.com">a link</a>.</p>
            <ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
            <ol start="3"><li><p>Three</p></li><li>Four</li></ol>
            <blockquote><p>Quoted</p></blockquote>
            <pre><code>let x = 1
            let y = 2</code></pre>
            <hr>
            <p>Line one<br>Line two &amp; more</p>
            <script>alert("no")</script>
            """
        XCTAssertEqual(HTMLMarkdown.convert(html), """
            # Title

            Some **bold**, _italic_ and [a link](https://example.com).

            - One
            - Two
              - Nested

            3. Three
            4. Four

            > Quoted

            ```
            let x = 1
            let y = 2
            ```

            ---

            Line one
            Line two & more
            """)
    }

    func testEmptyMarksAndLinksDisappear() {
        XCTAssertEqual(HTMLMarkdown.convert("<p>a<b></b> b <a href=\"#top\">top</a> <a href=\"https://x.org\">https://x.org</a></p>"),
                       "a b top https://x.org")
    }

    func testTables() {
        let html = "<table><tr><th>Name</th><th>Qty</th></tr><tr><td>Apples</td><td><b>3</b></td></tr><tr><td>A|B</td></tr></table><p>After</p>"
        XCTAssertEqual(HTMLMarkdown.convert(html), """
            | Name | Qty |
            | --- | --- |
            | Apples | **3** |
            | A\\|B |  |

            After
            """)
    }

    func testPictures() {
        let html = #"<p>See <img src="https://x.org/a.png" alt="A"> and <img src="local.png"> here</p>"#
        XCTAssertEqual(HTMLMarkdown.convert(html), "See\n![A](https://x.org/a.png)\nand here")
        XCTAssertEqual(HTMLMarkdown.convert(html) { "![](attachment:\($0.attributes["src"]!))" },
                       "See\n![](attachment:https://x.org/a.png)\nand\n![](attachment:local.png)\nhere")
    }

    func testEvernoteExport() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let pdf = Data("%PDF-1.4 fake".utf8)
        let enex = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export3.dtd">
            <en-export export-date="20261012T080000Z" application="Evernote" version="10.0">
            <note>
              <title>Shopping &amp; errands</title>
              <created>20230115T093000Z</created>
              <updated>20230116T101500Z</updated>
              <tag>home</tag><tag>lists</tag>
              <note-attributes><source-url>https://example.com/page</source-url></note-attributes>
              <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note><div>Buy:</div><div><en-todo checked="true"/>Milk</div><div><en-todo/>Bread</div><div><br/></div><div><en-media hash="\(MD5.hex(png))" type="image/png"/></div></en-note>]]></content>
              <resource><data encoding="base64">
            \(png.base64EncodedString())
              </data><mime>image/png</mime><resource-attributes><file-name>photo.png</file-name></resource-attributes></resource>
              <resource><data encoding="base64">\(pdf.base64EncodedString())</data><mime>application/pdf</mime></resource>
            </note>
            </en-export>
            """
        let notes = try XCTUnwrap(ENEX.parse(Data(enex.utf8)))
        XCTAssertEqual(notes.count, 1)
        let note = notes[0]
        XCTAssertEqual(note.title, "Shopping & errands")
        XCTAssertEqual(note.tags, ["home", "lists"])
        XCTAssertEqual(note.created, ENEX.date("20230115T093000Z"))
        XCTAssertEqual(note.created, Date(timeIntervalSince1970: 1_673_775_000))
        XCTAssertEqual(note.resources.map(\.data), [png, pdf])
        XCTAssertEqual(note.resources.map(\.suggestedName), ["photo.png", "Attachment.pdf"])

        let markdown = ENEX.markdown(of: note) { resource in
            resource.isPicture ? "![](attachment:\(resource.suggestedName))" : "[[\(resource.suggestedName)]]"
        }
        XCTAssertEqual(markdown, """
            Buy:
            - [x] Milk
            - [ ] Bread

            ![](attachment:photo.png)

            [[Attachment.pdf]]

            Source: [https://example.com/page](https://example.com/page)
            """)
        XCTAssertNil(ENEX.parse(Data("<rss/>".utf8)))
    }

    func testMarkdownFrontMatter() {
        let text = """
            ---
            title: "Trip plans"
            tags: [travel, "#italy"]
            created: 2024-03-01 09:15
            modified: 2024-03-02T10:00:00Z
            ---
            # Trip plans

            Rome first.
            """
        let note = MarkdownImport.note(fromMarkdown: text, fileName: "trip.md")
        XCTAssertEqual(note.title, "Trip plans")
        XCTAssertEqual(note.body, "Rome first.")
        XCTAssertEqual(note.tags, ["travel", "italy"])
        XCTAssertNotNil(note.created)
        XCTAssertEqual(note.modified, Date(timeIntervalSince1970: 1_709_373_600))

        let listed = MarkdownImport.note(fromMarkdown: "---\ntags:\n  - a\n  - b c\n---\nBody", fileName: "Plain.md")
        XCTAssertEqual(listed.title, "Plain")
        XCTAssertEqual(listed.tags, ["a", "b c"])
        XCTAssertEqual(listed.body, "Body")

        // A heading of its own, when the file name is the only other title.
        XCTAssertEqual(MarkdownImport.note(fromMarkdown: "# Real Title\nText", fileName: "x.md").title, "Real Title")
    }

    func testLocalPictures() {
        let text = "A ![cat](images/my%20cat.png \"Cat\") and ![web](https://x.org/a.png) and ![[dog.jpg|200]] and ![](<b c.gif>)"
        var asked: [String] = []
        let result = MarkdownImport.replacingLocalPictures(in: text) { path in
            asked.append(path)
            return path == "dog.jpg" ? nil : "![](attachment:\(asked.count).png)"
        }
        XCTAssertEqual(asked, ["images/my cat.png", "dog.jpg", "b c.gif"])
        XCTAssertEqual(result, "A ![](attachment:1.png) and ![web](https://x.org/a.png) and ![[dog.jpg|200]] and ![](attachment:3.png)")
    }

    func testHTMLNote() {
        let note = MarkdownImport.note(fromHTML: "<html><head><title>Recipe</title></head><body><h1>Recipe</h1><p>Mix.</p></body></html>",
                                       fileName: "r.html")
        XCTAssertEqual(note.title, "Recipe")
        XCTAssertEqual(note.body, "Mix.")
    }
}
