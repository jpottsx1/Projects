import XCTest
@testable import StashCore

final class MarkdownStylingTests: XCTestCase {
    private func styles(_ text: String) -> [String] {
        let string = text as NSString
        return MarkdownStyling.spans(in: text).map { span in
            let piece = string.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
            return "\(span.style):\(piece)"
        }
    }

    func testHeadingsAndInline() {
        XCTAssertEqual(styles("## Plan **now**"),
                       ["marker:## ", "heading(2):Plan **now**", "marker:**", "bold:now", "marker:**"])
        XCTAssertEqual(styles("say _hi_ and `x*y*z`"),
                       ["marker:_", "italic:hi", "marker:_", "marker:`", "code:x*y*z", "marker:`"])
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(styles("my_file_name"), [])
    }

    func testLinks() {
        XCTAssertEqual(styles("[Apple](https://apple.com) and [[Budget|the budget]]"),
                       ["marker:[", "link:Apple", "marker:](https://apple.com)",
                        "marker:[[", "marker:Budget|", "wikiLink:the budget", "marker:]]"])
    }

    func testListsTasksQuotesAndFences() {
        let text = "- [x] done\n1. first\n> said\n```\nlet *a* = 1\n```\n---"
        XCTAssertEqual(styles(text), [
            "listMarker:- ", "task(done: true):[x]",
            "listMarker:1. ",
            "marker:> ", "quote:said",
            "marker:```", "codeBlock:let *a* = 1", "marker:```",
            "rule:---",
        ])
    }

    func testOffsetsAreUTF16() {
        // The emoji is two UTF-16 units.
        let spans = MarkdownStyling.spans(in: "😀 **b**")
        XCTAssertEqual(spans.first?.range, 3..<5)
    }

    func testPlainText() {
        XCTAssertEqual(MarkdownStyling.plainText("- [ ] Pay **now**\n## Plan\nSee [[Budget|the budget]] and [x](https://x.org)"),
                       "Pay now Plan See the budget and x")
    }

    func testLinesTouchingSelection() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(MarkdownStyling.lines(touching: 5..<5, in: text), 4..<8)
        XCTAssertEqual(MarkdownStyling.lines(touching: 1..<9, in: text), 0..<13)
    }
}

final class MarkdownHTMLTests: XCTestCase {
    func testBlocksAndInline() {
        let html = MarkdownHTML.render("# Title\nSome **bold** & <b>.\n- one\n- [x] two\n1. first\n\n`a*b*`")
        XCTAssertEqual(html, """
            <h1>Title</h1>
            <p>Some <strong>bold</strong> &amp; &lt;b&gt;.</p>
            <ul>
            <li>one</li>
            <li class="task">☑ two</li>
            </ul>
            <ol>
            <li value="1">first</li>
            </ol>
            <p><code>a*b*</code></p>
            """)
    }

    func testLinks() {
        XCTAssertEqual(MarkdownHTML.inline("see [[Plan|the plan]] and [x](https://x.org)"),
                       #"see <em class="wiki">the plan</em> and <a href="https://x.org">x</a>"#)
    }
}

final class MentionsTests: XCTestCase {
    func testFindsWholeWordsNotInLinks() {
        let text = "The budget, [[Budget]], budgets and Budget."
        XCTAssertEqual(WikiLinks.unlinkedMentions(of: "Budget", in: text).map { String(text[$0]) }, ["budget", "Budget"])
    }

    func testLinkingKeepsTheWordsAsWritten() {
        XCTAssertEqual(WikiLinks.linkingMentions(of: "Budget", in: "The budget and Budget, [[Budget]]."),
                       "The [[Budget|budget]] and [[Budget]], [[Budget]].")
    }
}

final class NoteMergeTests: XCTestCase {
    func testMerge() {
        XCTAssertEqual(NoteMerge.merge([(title: "One", body: "first\n"), (title: "", body: ""), (title: "Three", body: "third")]),
                       "## One\n\nfirst\n\n## Untitled\n\n## Three\n\nthird")
    }
}

final class WidgetSnapshotTests: XCTestCase {
    func testRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = WidgetSnapshot(updatedAt: Date(timeIntervalSince1970: 1_000_000),
                                      recent: [.init(id: UUID(), title: "A", kind: "note", subtitle: "s")],
                                      reminders: [.init(id: UUID(), title: "B", kind: "link", subtitle: "",
                                                        date: Date(timeIntervalSince1970: 2_000_000))],
                                      inboxCount: 3)
        try snapshot.write(to: folder)
        XCTAssertEqual(WidgetSnapshot.read(from: folder), snapshot)
        XCTAssertEqual(WidgetSnapshot.itemURL(snapshot.recent[0].id).host, "item")
    }
}
