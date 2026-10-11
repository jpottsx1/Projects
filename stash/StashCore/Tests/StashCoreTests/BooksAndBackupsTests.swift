import XCTest
#if canImport(Compression)
import Compression
#endif
@testable import StashCore

/// A three-chapter EPUB 3 made with Python's zipfile: a stored mimetype,
/// everything else deflated, a chapter whose name has a space in it, and
/// a cover left out of the reading order.
private let sampleBook = Data(base64Encoded: "UEsDBBQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAACAC2lEtdHgvXyZkAAADdAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxVjsEOwiAQRH+l4Wpa9EoAExPPmvgFK90qEXYJUKN/L3qoeptk5s2M3j5i6O6Yi2cyYjOsxdZqx1TBE+Z/p2tZKkbMmRRD8UURRCyqOsUJaWQ3R6SqPjG1lAirM3OdfMDyld00h9AnqFcjDvvd8STfQMMHTpPoIo4e+vpMaASkFLyD2o5IxnMqDXM3uOCqLQlptfzpl8uufQFQSwMEFAAAAAgAtpRLXfFf/7kaAQAAhAIAABEAAABPRUJQUy9jb250ZW50Lm9wZp2SQW7DIBBFr4KQuqrqsd1Fpch2lJ4hUtcjGMcoGBCexu7tS5w4TqQu2u5g/v9vYKDaTr0VJ4qD8a6WRZbLbVMFVEc8kEiaG2rZMYcNwDiOmdGhzXw8QJnnb+BDK9fwawo3VU+MGhkv4Y1Wt3z4jHbOagVkqSfHAxRZASml1YYNW2r2HQmxp4HFu/fHCm7C2aIiIfvY7DLxEQ1TnPWlWsHSO50CnWkTpamSrRdG19LhSYouUjsvs6nj3krRkzb4wl+BaokhWKOQ021glp+nsyVEHyiyoeECgTuoKhYm08TgHT2VOf4e/sAqH1g8+n9yfHqSBTVv/sSBdXZDMI4u5ARL8BUphU0axjQSv3S/9xQ/FcuZf6XC9Zc131BLAwQUAAAACAC2lEtdRrHKnNUAAACfAQAADwAAAE9FQlBTL25hdi54aHRtbI2QTW6DMBCFr2K5ypYhdFGBhskiB0gXvYAJTkElHst2Y3L72iBFys+iu/n53hu9wd18nsRFOz+yaeW2KOWOcAhpmBbGt3IIwTYAMcYivhfsvmFb1zXMmZEr1Gj7292RY29PC1uV5Qew9ZKw4/5KaNRFZLwJV6tbGfiYVjwRTiOhEoPTpzTVcwA2elOVqlgv0X5QNmgnDkYjqP9o3nwl6VO5ILCjr8gIHS1SyDrIBkv15BIiP15d5PfSlOQpzqRMf1bux78IdeT05ptvbl46wvonyBz9AVBLAwQUAAAACAC2lEtd6gTBYykAAABBAAAAFgAAAE9FQlBTL3RleHQvb25lIGEueGh0bWyzySjJzbGzScpPqbSzKbDzSM3JyVfIz0vVU8DKtNEvsLPRh6jWB2sFAFBLAwQUAAAACAC2lEtdLb5wLR4AAAAkAAAAFAAAAE9FQlBTL3RleHQvdHdvLnhodG1ss8koyc2xs0nKT6m0symwCynPt9EvsLPRhwjog2UBUEsBAhQDFAAAAAAAAAAhAG9hqywUAAAAFAAAAAgAAAAAAAAAAAAAAIABAAAAAG1pbWV0eXBlUEsBAhQDFAAAAAgAtpRLXR4L18mZAAAA3QAAABYAAAAAAAAAAAAAAIABOgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQSwECFAMUAAAACAC2lEtd8V//uRoBAACEAgAAEQAAAAAAAAAAAAAAgAEHAQAAT0VCUFMvY29udGVudC5vcGZQSwECFAMUAAAACAC2lEtdRrHKnNUAAACfAQAADwAAAAAAAAAAAAAAgAFQAgAAT0VCUFMvbmF2LnhodG1sUEsBAhQDFAAAAAgAtpRLXeoEwWMpAAAAQQAAABYAAAAAAAAAAAAAAIABUgMAAE9FQlBTL3RleHQvb25lIGEueGh0bWxQSwECFAMUAAAACAC2lEtdLb5wLR4AAAAkAAAAFAAAAAAAAAAAAAAAgAGvAwAAT0VCUFMvdGV4dC90d28ueGh0bWxQSwUGAAAAAAYABgB8AQAA/wMAAAAA")!

#if canImport(Compression)
private func inflate(_ data: Data, _ size: Int) throws -> Data {
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                      input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    guard written == size else { throw Zip.Failure.damaged("inflate") }
    return output
}
#endif

private func noInflate(_ data: Data, _ size: Int) throws -> Data {
    throw Zip.Failure.unsupportedMethod(8)
}

final class ZipTests: XCTestCase {
    func testCRC() {
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        let split = Zip.crc32(Data("6789".utf8), continuing: Zip.crc32(Data("12345".utf8)))
        XCTAssertEqual(split, 0xCBF4_3926)
    }

    func testWriteThenRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.bin")
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        try big.write(to: source)

        let url = folder.appendingPathComponent("out.zip")
        let writer = try ZipWriter(url: url)
        try writer.add("Notes/Café ☕.md", data: Data("# Hi\n".utf8))
        try writer.add("Files/source.bin", contentsOf: source)
        try writer.add("empty.txt", data: Data())
        try writer.finish()

        let reader = try ZipReader(data: try Data(contentsOf: url, options: .alwaysMapped))
        XCTAssertEqual(reader.entries.map(\.path), ["Notes/Café ☕.md", "Files/source.bin", "empty.txt"])
        XCTAssertEqual(try reader.data(for: "Notes/Café ☕.md", inflate: noInflate), Data("# Hi\n".utf8))
        XCTAssertEqual(try reader.data(for: "Files/source.bin", inflate: noInflate), big)
        XCTAssertEqual(try reader.data(for: "empty.txt", inflate: noInflate), Data())
        XCTAssertThrowsError(try reader.data(for: "missing", inflate: noInflate))
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipReader(data: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? Zip.Failure, .notAZip)
        }
    }

    func testStoredEntryNeedsNoInflating() throws {
        let reader = try ZipReader(data: sampleBook)
        XCTAssertEqual(String(decoding: try reader.data(for: "mimetype", inflate: noInflate), as: UTF8.self),
                       "application/epub+zip")
    }
}

#if canImport(Compression)
final class EPUBTests: XCTestCase {
    func testReadsSpineTOCAndTitle() throws {
        let zip = try ZipReader(data: sampleBook)
        let book = try EPUBBook { try zip.data(for: $0, inflate: inflate) }
        XCTAssertEqual(book.title, "The Test Book")
        XCTAssertEqual(book.author, "A. Writer")
        XCTAssertEqual(book.chapters.map(\.path), ["OEBPS/text/one a.xhtml", "OEBPS/text/two.xhtml"])
        XCTAssertEqual(book.toc, [
            .init(title: "Chapter One", target: "OEBPS/text/one a.xhtml", level: 0),
            .init(title: "Part Two", target: "OEBPS/text/one a.xhtml#s2", level: 1),
            .init(title: "Chapter Two", target: "OEBPS/text/two.xhtml", level: 0),
        ])
        XCTAssertEqual(book.chapterIndex(for: "OEBPS/text/one a.xhtml#s2"), 0)
        XCTAssertEqual(String(decoding: try zip.data(for: book.chapters[1].path, inflate: inflate), as: UTF8.self),
                       "<html><body><p>Two</p></body></html>")
    }
}
#endif

final class EPUBPathTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(EPUBBook.resolve("../images/a%20b.png", from: "OEBPS/text/"), "OEBPS/images/a b.png")
        XCTAssertEqual(EPUBBook.resolve("./c.xhtml#x", from: "OEBPS/"), "OEBPS/c.xhtml#x")
        XCTAssertEqual(EPUBBook.resolve("c.xhtml", from: ""), "c.xhtml")
    }
}

final class TextQuoteTests: XCTestCase {
    func testPicksTheRightRepeat() throws {
        let text = "Hello one. Hello one. Hello one."
        // The second "Hello", 11 UTF-16 units in.
        let quote = try XCTUnwrap(TextQuote(in: text, start: 11, end: 16))
        XCTAssertEqual(quote.exact, "Hello")
        XCTAssertEqual(quote.locate(in: text), 11..<16)
        // Still found after text is added before it.
        XCTAssertEqual(quote.locate(in: "Intro. " + text), 18..<23)
        XCTAssertNil(quote.locate(in: "Goodbye"))
    }

    func testCountsLikeJavaScript() throws {
        let text = "😀 café — note"
        // The emoji is two UTF-16 units, as in a browser.
        let quote = try XCTUnwrap(TextQuote(in: text, start: 3, end: 7))
        XCTAssertEqual(quote.exact, "café")
        XCTAssertNil(TextQuote(in: text, start: 5, end: 5))
    }

    func testAnchorJSONRoundTrip() {
        let anchors: [HighlightAnchor] = [
            .pdf([.init(page: 2, rects: [.init(x: 1, y: 2, width: 3.5, height: 4)])]),
            .epub(chapter: "OEBPS/one.xhtml", quote: TextQuote(exact: "a", prefix: "b", suffix: "c")),
            .article(quote: TextQuote(exact: "d")),
        ]
        for anchor in anchors {
            XCTAssertEqual(HighlightAnchor(json: anchor.json), anchor)
        }
        XCTAssertNil(HighlightAnchor(json: "nonsense"))
    }
}

final class LabelsAndRatingsSearchTests: XCTestCase {
    func testFilters() {
        XCTAssertEqual(SearchQuery("is:due is:reminder").flags, [.due, .reminder])
        let query = SearchQuery("label:Red label:grey label:none rating:>=4 is:unread is:inbox")
        XCTAssertEqual(query.labels, [.red, .gray, .none])
        XCTAssertEqual(query.minimumRating, 4)
        XCTAssertEqual(query.flags, [.unread, .inbox])
        XCTAssertNil(query.ftsExpression)
    }

    func testBadValuesAreWords() {
        let query = SearchQuery("label:chartreuse rating:9")
        XCTAssertTrue(query.labels.isEmpty)
        XCTAssertNil(query.minimumRating)
        XCTAssertEqual(query.terms.count, 2)
    }
}

final class BackupTests: XCTestCase {
    func testManifestRoundTrip() throws {
        let work = UUID(), clients = UUID()
        var item = BackupManifest.ItemRecord(id: UUID(), kind: "note", title: "Plan",
                                             createdAt: Date(timeIntervalSince1970: 1_000_000),
                                             modifiedAt: Date(timeIntervalSince1970: 2_000_000))
        item.tags = ["work"]
        item.category = clients
        item.highlights = [.init(id: UUID(), text: "x", note: "y", color: "yellow", anchor: "{}",
                                 position: 1, createdAt: Date(timeIntervalSince1970: 3_000_000))]
        let manifest = BackupManifest(
            exportedAt: Date(timeIntervalSince1970: 4_000_000),
            categories: [.init(id: work, name: "Work", parent: nil), .init(id: clients, name: "Clients/Old", parent: work)],
            items: [item])
        XCTAssertEqual(try BackupManifest.decode(try manifest.encoded()), manifest)
        XCTAssertEqual(manifest.folder(for: clients), "Work/Clients-Old")
        XCTAssertEqual(manifest.folder(for: nil), "")
    }

    func testOlderBackupsWithoutRulesStillRead() throws {
        let json = #"{"version":1,"exportedAt":"2026-01-01T00:00:00Z","categories":[],"smartFilters":[],"items":[]}"#
        let manifest = try BackupManifest.decode(Data(json.utf8))
        XCTAssertNil(manifest.rules)
        var withRules = manifest
        withRules.rules = [.init(id: UUID(), name: "Invoices", query: "invoice kind:pdf", isEnabled: true,
                                 createdAt: Date(timeIntervalSince1970: 0), category: nil, tags: "money", label: 1,
                                 rating: -1, makesFavorite: false, marksRead: true, takesOutOfInbox: true)]
        XCTAssertEqual(try BackupManifest.decode(try withRules.encoded()), withRules)
    }

    func testUniqueNames() {
        var taken: Set<String> = []
        XCTAssertEqual(ExportNaming.unique("Plan", ext: "md", in: "Work", taken: &taken), "Work/Plan.md")
        XCTAssertEqual(ExportNaming.unique("plan", ext: "md", in: "Work", taken: &taken), "Work/plan 2.md")
        XCTAssertEqual(ExportNaming.unique("a/b: c", ext: "", in: "", taken: &taken), "a-b- c")
        XCTAssertEqual(ExportNaming.safe("..hidden"), "hidden")
        XCTAssertEqual(ExportNaming.safe("  "), "Untitled")
    }

    func testMarkdown() {
        var item = BackupManifest.ItemRecord(id: UUID(), kind: "link", title: "Bread: a \"guide\"",
                                             createdAt: Date(timeIntervalSince1970: 0),
                                             modifiedAt: Date(timeIntervalSince1970: 86400))
        item.url = "https://example.com/bread?x=1"
        item.tags = ["baking", "to-read"]
        item.summary = "All about bread."
        item.body = "My notes."
        item.rating = 4
        item.label = ItemLabel.green.rawValue
        item.highlights = [
            .init(id: UUID(), text: "Second", note: "", color: "yellow", anchor: "", position: 2, createdAt: .init()),
            .init(id: UUID(), text: "First", note: "Why", color: "yellow", anchor: "", position: 1, createdAt: .init()),
        ]
        XCTAssertEqual(ExportMarkdown.render(item, category: "Food"), """
            ---
            title: "Bread: a \\"guide\\""
            kind: link
            url: "https://example.com/bread?x=1"
            category: Food
            tags: [baking, to-read]
            created: 1970-01-01T00:00:00Z
            modified: 1970-01-02T00:00:00Z
            label: green
            rating: 4
            ---

            > All about bread.

            My notes.

            ## Highlights

            > First

            Why

            > Second

            """)
    }
}

final class ReminderDatesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 11th is a Sunday.
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testLaterToday() {
        XCTAssertEqual(ReminderDates.laterToday(now: date(12, 10, 25), calendar: calendar), date(12, 13))
        XCTAssertNil(ReminderDates.laterToday(now: date(12, 19, 30), calendar: calendar))
        XCTAssertNil(ReminderDates.laterToday(now: date(12, 23), calendar: calendar))
    }

    func testMornings() {
        let wednesday = date(14, 15)
        XCTAssertEqual(ReminderDates.tomorrowMorning(now: wednesday, calendar: calendar), date(15, 9))
        XCTAssertEqual(ReminderDates.thisWeekend(now: wednesday, calendar: calendar), date(17, 9))
        XCTAssertEqual(ReminderDates.nextWeek(now: wednesday, calendar: calendar), date(19, 9))
        // On a Saturday, "this weekend" is next Saturday, and on a Monday next week is the next Monday.
        XCTAssertEqual(ReminderDates.thisWeekend(now: date(17, 8), calendar: calendar), date(24, 9))
        XCTAssertEqual(ReminderDates.nextWeek(now: date(12, 8), calendar: calendar), date(19, 9))
    }
}
