import XCTest
@testable import StashCore

final class TranscriptTests: XCTestCase {
    private let transcript = Transcript(segments: [
        .init(start: 0.5, end: 2.0, text: "Hello there."),
        .init(start: 2.2, end: 4.0, text: "This is a test."),
        .init(start: 7.0, end: 9.0, text: "After a pause."),
    ])

    func testParagraphsBreakAtPauses() {
        XCTAssertEqual(transcript.text(), "Hello there. This is a test.\n\nAfter a pause.")
    }

    func testFollowingAlong() {
        XCTAssertNil(transcript.segmentIndex(at: 0.1))
        XCTAssertEqual(transcript.segmentIndex(at: 0.5), 0)
        XCTAssertEqual(transcript.segmentIndex(at: 3), 1)
        // In the pause, the last thing said.
        XCTAssertEqual(transcript.segmentIndex(at: 5), 1)
        XCTAssertEqual(transcript.segmentIndex(at: 100), 2)
    }

    func testWordsMakePhrases() {
        let words: [(text: String, start: Double, duration: Double)] = [
            ("Buy", 0, 0.3), ("milk.", 0.35, 0.3), ("Then", 0.8, 0.2), ("call", 1.05, 0.2),
            ("Sam", 3.0, 0.3), ("back", 3.35, 0.3),
        ]
        let phrases = Transcript.phrases(fromWords: words)
        XCTAssertEqual(phrases.map(\.text), ["Buy milk.", "Then call", "Sam back"])
        XCTAssertEqual(phrases.map(\.start), [0, 0.8, 3.0])
        for (phrase, end) in zip(phrases, [0.65, 1.25, 3.65]) { XCTAssertEqual(phrase.end, end, accuracy: 0.001) }
    }

    func testTimestampsAndJSON() {
        XCTAssertEqual(Transcript.timestamp(65.7), "1:05")
        XCTAssertEqual(Transcript.timestamp(3723), "1:02:03")
        XCTAssertEqual(Transcript(json: transcript.json!), transcript)
    }
}

final class EmailTests: XCTestCase {
    func testPlainMessage() throws {
        let eml = """
            From: =?utf-8?Q?Ren=C3=A9e_Smith?= <renee@example.com>
            To: "Doe, Jane" <jane@example.com>, bob@example.org
            Subject: =?UTF-8?B?Q2Fmw6k=?= plans
             for Friday
            Date: Mon, 12 Oct 2026 08:30:00 +0000 (UTC)
            Message-ID: <abc123@example.com>
            Content-Type: text/plain; charset="utf-8"
            Content-Transfer-Encoding: quoted-printable

            Shall we meet at the caf=C3=A9 at ten? It's a long line that wraps=
             here.
            """
        let message = try XCTUnwrap(MIMEMessage(Data(eml.utf8)))
        XCTAssertEqual(message.subject, "Café plans for Friday")
        XCTAssertEqual(message.from, [.init(name: "Renée Smith", email: "renee@example.com")])
        XCTAssertEqual(message.to.map(\.display), ["Doe, Jane", "bob@example.org"])
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_791_793_800))
        XCTAssertEqual(message.messageID, "abc123@example.com")
        XCTAssertEqual(message.textBody, "Shall we meet at the café at ten? It's a long line that wraps here.")
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testMultipartWithAttachment() throws {
        let pdf = Data("%PDF-1.4 pretend".utf8)
        let eml = """
            From: Sam <sam@example.com>\r
            Subject: Invoice\r
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="outer"\r
            \r
            This is a multi-part message.\r
            --outer\r
            Content-Type: multipart/alternative; boundary=inner\r
            \r
            --inner\r
            Content-Type: text/plain; charset=us-ascii\r
            \r
            See attached.\r
            --inner\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <p>See <b>attached</b>.</p>\r
            --inner--\r
            --outer\r
            Content-Type: application/pdf; name="invoice.pdf"\r
            Content-Disposition: attachment; filename*=utf-8''na%C3%AFve%20invoice.pdf\r
            Content-Transfer-Encoding: base64\r
            \r
            \(pdf.base64EncodedString())\r
            --outer--\r
            """
        let message = try XCTUnwrap(MIMEMessage(Data(eml.utf8)))
        XCTAssertEqual(message.textBody, "See attached.")
        XCTAssertEqual(message.htmlBody, "<p>See <b>attached</b>.</p>")
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.fileName, "naïve invoice.pdf")
        XCTAssertEqual(message.attachments.first?.mimeType, "application/pdf")
        XCTAssertEqual(message.attachments.first?.data, pdf)
    }

    func testHTMLOnlyReadsAsText() throws {
        let eml = "Subject: News\nContent-Type: text/html\n\n<h1>Big news</h1><p>We <i>launched</i>.</p>"
        let message = try XCTUnwrap(MIMEMessage(Data(eml.utf8)))
        XCTAssertNil(message.textBody)
        XCTAssertEqual(message.plainText, "# Big news\n\nWe _launched_.")
    }

    func testNotAMessage() {
        XCTAssertNil(MIMEMessage(Data("just some text\nwith lines".utf8)))
    }

    func testMbox() throws {
        let mbox = """
            From sam@example.com Mon Oct 12 08:30:00 2026
            Subject: One

            First body
            >From the start of a line.

            From jo@example.com Mon Oct 12 09:30:00 2026
            Subject: Two

            Second body
            """
        let messages = Mbox.messages(in: Data(mbox.utf8)).compactMap(MIMEMessage.init)
        XCTAssertEqual(messages.map(\.subject), ["One", "Two"])
        XCTAssertEqual(messages.first?.textBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "First body\nFrom the start of a line.")
    }

    func testEmailKindInSearch() {
        XCTAssertEqual(SearchQuery("kind:email").kinds, [.email])
    }
}

final class AnnotationSummaryTests: XCTestCase {
    private let entries = [
        AnnotationSummary.Entry(text: "The first idea.", note: "Worth a closer look.", color: .yellow, location: "p. 3"),
        AnnotationSummary.Entry(text: "Two lines\nof text", color: .blue),
    ]

    func testNoteForOneItem() {
        let note = AnnotationSummary.note(for: .init(title: "Deep Work", url: "https://www.example.com/book", entries: entries))
        XCTAssertEqual(note, """
            From [[Deep Work]] · [example.com](https://www.example.com/book)

            > 🟨 The first idea.

            _p. 3_

            Worth a closer look.

            > 🟦 Two lines
            > of text
            """)
        XCTAssertEqual(AnnotationSummary.noteTitle(for: "Deep Work"), "Highlights: Deep Work")
    }

    func testLocations() {
        XCTAssertEqual(AnnotationSummary.location(of: .pdf([.init(page: 11, rects: [])]), position: 11.3), "p. 12")
        XCTAssertEqual(AnnotationSummary.location(of: .epub(chapter: "c.xhtml", quote: .init(exact: "x", prefix: "", suffix: "")),
                                                  position: 2.5), "Chapter 3")
        XCTAssertNil(AnnotationSummary.location(of: .article(quote: .init(exact: "x", prefix: "", suffix: "")), position: 0))
    }

    func testWholeLibrary() {
        let text = AnnotationSummary.library([.init(title: "A", entries: entries), .init(title: "Empty", entries: [])],
                                             exportedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.hasPrefix("# Highlights\n\n2 highlights from 2 items"))
        XCTAssertTrue(text.contains("## A\n\n> 🟨 The first idea."))
        XCTAssertFalse(text.contains("## Empty"))
    }
}
