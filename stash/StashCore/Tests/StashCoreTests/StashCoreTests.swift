import XCTest
@testable import StashCore

final class WikiLinksTests: XCTestCase {
    func testFindsTitlesOnceInOrder() {
        let text = "See [[Budget]] and [[Trip|the trip]], then [[budget]] again."
        XCTAssertEqual(WikiLinks.titles(in: text), ["Budget", "Trip"])
    }

    func testIgnoresBrokenLinks() {
        XCTAssertEqual(WikiLinks.titles(in: "[[]] [[ ]] [[open\nclose]] [single]"), [])
    }

    func testRenamingKeepsShownText() {
        let text = "[[Old]] and [[old|label]] but not [[Older]]"
        XCTAssertEqual(WikiLinks.renaming("Old", to: "New", in: text),
                       "[[New]] and [[New|label]] but not [[Older]]")
    }

    func testMarkdownLinksRoundTrip() {
        let markdown = WikiLinks.markdownLinks(in: "Go to [[Q&A notes|questions]].", scheme: "stash")
        XCTAssertEqual(markdown, "Go to [questions](stash://open?title=Q%26A%20notes).")
        let url = URL(string: WikiLinks.url(for: "Q&A notes", scheme: "stash"))!
        XCTAssertEqual(WikiLinks.title(from: url, scheme: "stash"), "Q&A notes")
    }
}

final class TagNameTests: XCTestCase {
    func testCleaning() {
        XCTAssertEqual(TagName.clean("  #to   read "), "to-read")
        XCTAssertEqual(TagName.key("#Work"), "work")
    }

    func testSplitDropsDuplicatesAndBlanks() {
        XCTAssertEqual(TagName.split("work, Work, , to read,#ideas"), ["work", "to-read", "ideas"])
    }
}

final class SearchQueryTests: XCTestCase {
    func testWordsPhrasesAndTags() {
        let query = SearchQuery(#"budget "next year" #Work #work"#)
        XCTAssertEqual(query.terms, [.word("budget"), .phrase("next year")])
        XCTAssertEqual(query.tags, ["work"])
        XCTAssertEqual(query.ftsExpression, #""budget"* "next year""#)
    }

    func testNothingTypedCanBreakTheExpression() {
        XCTAssertEqual(SearchQuery(#"a"b"#).ftsExpression, #""a"* "b""#)
        XCTAssertEqual(SearchQuery("AND OR NOT").ftsExpression, #""AND"* "OR"* "NOT"*"#)
        XCTAssertNil(SearchQuery("- * ()").ftsExpression)
    }

    func testTagsOnly() {
        let query = SearchQuery("#ideas")
        XCTAssertNil(query.ftsExpression)
        XCTAssertFalse(query.isEmpty)
    }

    func testColumnPhrase() {
        XCTAssertEqual(SearchQuery.phrase(#"My "big" note"#, inColumn: "body"),
                       #"body : "My ""big"" note""#)
    }
}

final class MarkdownBlocksTests: XCTestCase {
    func testBlocks() {
        let text = """
        # Title
        First line
        continues here.

        - one
          - two
        - [ ] todo
        - [x] done
        3. third
        > quoted
        > more
        ---
        ```swift
        let x = 1
        ```
        """
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line continues here."),
            .bullet(indent: 0, text: "one"),
            .bullet(indent: 1, text: "two"),
            .task(indent: 0, done: false, text: "todo", line: 6),
            .task(indent: 0, done: true, text: "done", line: 7),
            .numbered(indent: 0, number: 3, text: "third"),
            .quote("quoted more"),
            .rule,
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    func testHashtagIsNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("#idea"), [.paragraph("#idea")])
    }

    func testToggleTask() {
        let text = "a\n- [ ] buy milk\n- [x] done"
        XCTAssertEqual(MarkdownBlocks.toggleTask(onLine: 1, in: text), "a\n- [x] buy milk\n- [x] done")
        XCTAssertEqual(MarkdownBlocks.toggleTask(onLine: 2, in: text), "a\n- [ ] buy milk\n- [ ] done")
        XCTAssertEqual(MarkdownBlocks.toggleTask(onLine: 0, in: text), text)
    }
}

final class HTMLTextTests: XCTestCase {
    func testExtractsTitleSummaryAndText() {
        let html = """
        <html><head><title> Hello &amp; welcome </title>
        <meta name="description" content="A page about &quot;things&quot;.">
        <style>body { color: red }</style></head>
        <body><script>var x = "<p>no</p>";</script>
        <h1>Big   heading</h1><p>Some&nbsp;text &#8212; here&#x21;</p><!-- hidden --></body></html>
        """
        let page = HTMLText.extract(from: html)
        XCTAssertEqual(page.title, "Hello & welcome")
        XCTAssertEqual(page.summary, "A page about \"things\".")
        XCTAssertEqual(page.text, "Big heading Some text \u{2014} here!")
    }

    func testFallsBackToOpenGraph() {
        let page = HTMLText.extract(from: #"<meta property='og:title' content='OG'><meta property="og:description" content="Desc">"#)
        XCTAssertEqual(page.title, "OG")
        XCTAssertEqual(page.summary, "Desc")
    }
}

final class WebAddressTests: XCTestCase {
    func testAddresses() {
        XCTAssertEqual(WebAddress.url(from: " example.com/page ")?.absoluteString, "https://example.com/page")
        XCTAssertEqual(WebAddress.url(from: "http://a.org")?.absoluteString, "http://a.org")
        XCTAssertNil(WebAddress.url(from: "not a url"))
        XCTAssertNil(WebAddress.url(from: "ftp://files.example.com"))
        XCTAssertNil(WebAddress.url(from: "hello"))
        XCTAssertEqual(WebAddress.displayHost(of: URL(string: "https://www.example.com/x")!), "example.com")
    }
}

final class SharedInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEntriesComeBackOldestFirstWithTheirFiles() throws {
        let inbox = SharedInbox(root: root)
        let file = root.appendingPathComponent("Report.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: file)

        // Whole seconds: the dates are stored as ISO 8601.
        let newer = SharedEntry(kind: .file, title: "Report", tags: ["work"], createdAt: Date(timeIntervalSince1970: 2000))
        let older = SharedEntry(kind: .link, title: "Article", url: "https://example.com", createdAt: Date(timeIntervalSince1970: 1000))
        try inbox.add(newer, file: file)
        try inbox.add(older)

        let pending = inbox.pending()
        XCTAssertEqual(pending.map(\.entry.title), ["Article", "Report"])
        XCTAssertEqual(pending[0].entry, older)
        XCTAssertEqual(pending[1].entry.fileName, "Report.pdf")
        XCTAssertEqual(try pending[1].file.map { try Data(contentsOf: $0) }, Data("pdf".utf8))
        XCTAssertNil(pending[0].file)

        inbox.remove(pending[0])
        XCTAssertEqual(inbox.pending().map(\.entry.title), ["Report"])
    }

    func testAFolderWithoutItsEntryIsLeftAlone() throws {
        // What a share still copying its file in looks like.
        let half = root.appendingPathComponent("Inbox/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        XCTAssertTrue(SharedInbox(root: root).pending().isEmpty)
    }

    func testCategoriesRoundTrip() {
        let inbox = SharedInbox(root: root)
        XCTAssertEqual(inbox.categories(), [])
        let categories = [SharedCategory(id: UUID(), path: "Work"), SharedCategory(id: UUID(), path: "Work › Clients")]
        inbox.writeCategories(categories)
        XCTAssertEqual(inbox.categories(), categories)
    }
}

final class WikiLinkCompletionTests: XCTestCase {
    /// The context with the cursor where "|" is written in `marked`.
    private func context(_ marked: String) -> WikiLinkCompletion.Context? {
        let cursorOffset = marked.distance(from: marked.startIndex, to: marked.firstIndex(of: "|")!)
        var text = marked
        text.remove(at: text.firstIndex(of: "|")!)
        return WikiLinkCompletion.context(in: text, cursor: text.index(text.startIndex, offsetBy: cursorOffset))
    }

    func testFindsTheUnfinishedLink() {
        XCTAssertEqual(context("See [[shop|")?.query, "shop")
        XCTAssertEqual(context("See [[|")?.query, "")
        XCTAssertEqual(context("[[two words| after")?.query, "two words")
    }

    func testNoContextOutsideALink() {
        XCTAssertNil(context("plain text|"))
        XCTAssertNil(context("[[done]] then|"))
        XCTAssertNil(context("[[line\nbreak|"))
        XCTAssertNil(context("[single|"))
    }

    func testCompletingReplacesTheQueryAndPlacesTheCursor() {
        let text = "See [[sho and more"
        let cursor = text.index(text.startIndex, offsetBy: 9)  // after "sho"
        let found = WikiLinkCompletion.context(in: text, cursor: cursor)!
        let done = WikiLinkCompletion.complete(text, context: found, with: "Shopping List")
        XCTAssertEqual(done.text, "See [[Shopping List]] and more")
        XCTAssertEqual(String(done.text[..<done.cursor]), "See [[Shopping List]]")
    }

    func testCompletingReusesClosingBrackets() {
        let text = "[[sh]]"
        let found = WikiLinkCompletion.context(in: text, cursor: text.index(text.startIndex, offsetBy: 4))!
        XCTAssertEqual(WikiLinkCompletion.complete(text, context: found, with: "Shop").text, "[[Shop]]")
    }

    func testEditPoint() {
        func offset(_ old: String, _ new: String) -> Int {
            new.distance(from: new.startIndex, to: WikiLinkCompletion.editPoint(from: old, to: new))
        }
        XCTAssertEqual(offset("abc", "abXc"), 3)   // typed X after b
        XCTAssertEqual(offset("a[", "a[["), 3)     // a repeated character
        XCTAssertEqual(offset("abc", "ac"), 1)     // deleted b
        XCTAssertEqual(offset("", "x"), 1)
    }

    func testRanking() {
        let titles = ["Weekly Shop", "Shopping List", "Bishop", "Notes", "shopping list"]
        XCTAssertEqual(WikiLinkCompletion.rank(titles, for: "shop"), ["Shopping List", "Weekly Shop", "Bishop"])
        XCTAssertEqual(WikiLinkCompletion.rank(titles, for: "", limit: 2), ["Weekly Shop", "Shopping List"])
    }
}
