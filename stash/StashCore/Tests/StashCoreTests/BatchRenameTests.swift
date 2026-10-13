import XCTest
@testable import StashCore

final class BatchRenameTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let sources = [
        BatchRename.Source(title: "Scan 001 invoice", created: Date(timeIntervalSince1970: 1_791_813_900), kind: "Document"),
        BatchRename.Source(title: "scan 002 Receipt", created: Date(timeIntervalSince1970: 1_791_900_300), kind: "Document"),
    ]

    func testFindAndReplace() {
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .replace(find: "scan", replace: "Doc", ignoringCase: true, regex: false)),
                       ["Doc 001 invoice", "Doc 002 Receipt"])
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .replace(find: "scan", replace: "Doc", ignoringCase: false, regex: false)),
                       ["Scan 001 invoice", "Doc 002 Receipt"])
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .replace(find: #"(?i)scan (\d+) (\w+)"#, replace: "$2 #$1",
                                                                      ignoringCase: false, regex: true)),
                       ["invoice #001", "Receipt #002"])
        // A bad expression changes nothing.
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .replace(find: "(", replace: "", ignoringCase: false, regex: true)),
                       sources.map(\.title))
    }

    func testAddingAndPatterns() {
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .add(prefix: "2026 – ", suffix: " (paid)")),
                       ["2026 – Scan 001 invoice (paid)", "2026 – scan 002 Receipt (paid)"])
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .pattern("{date} {kind} {n}", start: 9, digits: 3),
                                          calendar: calendar, locale: Locale(identifier: "en_US_POSIX")),
                       ["2026-10-12 Document 009", "2026-10-13 Document 010"])
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .pattern("{Title} – {date:MMM d}", start: 1, digits: 1),
                                          calendar: calendar, locale: Locale(identifier: "en_US_POSIX")),
                       ["Scan 001 invoice – Oct 12", "scan 002 Receipt – Oct 13"])
        // An empty result keeps the old title.
        XCTAssertEqual(BatchRename.titles(for: sources, mode: .pattern("  ", start: 1, digits: 1)), sources.map(\.title))
    }

    func testPlainLines() {
        let markdown = "# Plan\n\n- **Buy** milk\n- [Call](https://x.org) Sam\n\n\n![](attachment:a.png)\n\nThe _end_."
        XCTAssertEqual(MarkdownStyling.plainLines(markdown), "Plan\n\n- Buy milk\n- Call Sam\n\nThe end.")
    }
}

final class EventsPlaceholderTests: XCTestCase {
    func testEventsFillIn() {
        var values = NoteTemplate.Values()
        values.events = "- 09:00–09:30 Standup"
        XCTAssertEqual(NoteTemplate.fill("## Today\n\n{{events}}", with: values), "## Today\n\n- 09:00–09:30 Standup")
    }
}
