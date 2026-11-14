import XCTest
@testable import StashCore

final class NoteBlocksTests: XCTestCase {
    private let note = """
        # Trip

        Pack light.
        Really light.

        - Passport
        - [ ] Tickets
          - [x] Seats
        1. Book hotel
        2. Pay

        > Travel is the only thing
        > you buy that makes you richer.

        ```swift
        let x = 1
        ```

        <details>
        <summary>Packing list</summary>

        - Socks
        - Charger

        </details>

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ---

        #### Small heading
        """

    func testRoundTrip() {
        let blocks = NoteBlocks.split(note)
        XCTAssertEqual(blocks.map(\.kind), [.heading1, .text, .bullet, .todo, .todo, .numbered, .numbered, .quote, .code,
                                            .toggle, .raw, .divider, .raw])
        XCTAssertEqual(blocks[1].text, "Pack light.\nReally light.")
        XCTAssertEqual(blocks[4].indent, 1)
        XCTAssertTrue(blocks[4].done)
        XCTAssertEqual(blocks[8].body, "swift")
        XCTAssertEqual(blocks[9].text, "Packing list")
        XCTAssertEqual(blocks[9].body, "- Socks\n- Charger")
        XCTAssertEqual(NoteBlocks.join(blocks), note)
        XCTAssertEqual(NoteBlocks.split(NoteBlocks.join(blocks)), blocks.map { $0 }.enumerated().map { index, block in
            var same = NoteBlocks.split(NoteBlocks.join(blocks))[index]
            same.id = block.id
            return same
        })
    }

    func testConvertingAndMoving() {
        let blocks = NoteBlocks.split("First\n\nSecond")
        let heading = blocks[1].converted(to: .heading2)
        XCTAssertEqual(NoteBlocks.join([blocks[0], heading]), "First\n\n## Second")
        let moved = NoteBlocks.moving(blocks, from: 1, to: 0)
        XCTAssertEqual(NoteBlocks.join(moved), "Second\n\nFirst")
        let toggle = NoteBlock(kind: .toggle, text: "More", body: "Hidden")
        XCTAssertEqual(toggle.converted(to: .text).text, "More\n\nHidden")
        XCTAssertEqual(NoteBlocks.join([NoteBlock(kind: .numbered, text: "a"), NoteBlock(kind: .numbered, text: "b")]), "1. a\n2. b")
    }

    func testTogglesInThePreview() {
        let blocks = MarkdownBlocks.parse("Intro\n\n<details>\n<summary>More</summary>\n\n- [ ] Inside\n\n</details>\n\nAfter")
        guard case .toggle(let title, let body, let line)? = blocks.dropFirst().first else { return XCTFail("No toggle") }
        XCTAssertEqual(title, "More")
        XCTAssertEqual(body, "- [ ] Inside")
        XCTAssertEqual(line, 5)
        XCTAssertEqual(blocks.last, .paragraph("After"))
    }
}

final class SlashCommandTests: XCTestCase {
    func testCommands() throws {
        let text = "Intro\n  /tog"
        let context = try XCTUnwrap(SlashCommands.context(in: text, cursor: text.endIndex))
        XCTAssertEqual(context.query, "tog")
        XCTAssertEqual(SlashCommands.matching("tog").map(\.name), ["Toggle"])
        XCTAssertEqual(SlashCommands.matching("h").first?.name, "Heading 1")
        let toggle = try XCTUnwrap(SlashCommands.matching("toggle").first)
        let done = SlashCommands.apply(toggle, to: text, context: context, today: "2026-10-15")
        XCTAssertEqual(done.text, "Intro\n  <details>\n<summary></summary>\n\n\n\n</details>")
        XCTAssertEqual(done.cursor, "Intro\n  <details>\n<summary>".count)
        XCTAssertNil(SlashCommands.context(in: "a /b", cursor: "a /b".endIndex))
        XCTAssertNil(SlashCommands.context(in: "/two words", cursor: "/two words".endIndex))
        let date = try XCTUnwrap(SlashCommands.all.first { $0.name == "Today’s Date" })
        XCTAssertEqual(SlashCommands.apply(date, to: "/date", context: SlashCommands.context(in: "/date", cursor: "/date".endIndex)!,
                                           today: "2026-10-15").text, "2026-10-15")
    }

    func testMovingTheCursorsBlock() throws {
        let text = "# Title\n\nFirst\n\n- a\n- b"
        let moved = try XCTUnwrap(NoteBlocks.movingBlock(at: 2, by: -1, in: text))
        XCTAssertEqual(moved.text, "First\n\n# Title\n\n- a\n- b")
        XCTAssertEqual(moved.line, 0)
        XCTAssertNil(NoteBlocks.movingBlock(at: 0, by: -1, in: text))
        XCTAssertEqual(NoteBlocks.movingBlock(at: 4, by: 1, in: text)?.text, "# Title\n\nFirst\n\n- b\n- a")
    }

    func testTogglesWhileWriting() {
        let spans = MarkdownStyling.spans(in: "<details>\n<summary>More</summary>\nText\n</details>")
        XCTAssertTrue(spans.contains { $0.style == .toggleTitle && $0.range == 19..<23 })
        XCTAssertEqual(spans.first?.style, .marker)
    }
}
