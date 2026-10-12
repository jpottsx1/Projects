import XCTest
@testable import StashCore

final class LibraryQuestionTests: XCTestCase {
    func testSearchWordsLeaveOutTheAsking() {
        XCTAssertEqual(Set(LibraryQuestion.searchWords(in: "What did I note about the boiler service?")),
                       ["boiler", "service", "note"])
        XCTAssertEqual(LibraryQuestion.searchWords(in: "How many?"), [])
    }

    func testPassageFindsTheRightPart() {
        let filler = String(repeating: "Nothing much happened today. ", count: 40)
        let text = filler + "The boiler was serviced in March by Ray. It needs a new valve next year. " + filler
        let passage = LibraryQuestion.passage(in: text, words: ["boiler", "valve"], length: 200)
        XCTAssertTrue(passage.contains("The boiler was serviced in March by Ray."), passage)
        XCTAssertTrue(passage.contains("new valve"), passage)
        XCTAssertLessThanOrEqual(passage.count, 201)
        // Short text comes whole.
        XCTAssertEqual(LibraryQuestion.passage(in: "Short  text.", words: ["x"]), "Short text.")
    }

    func testPromptAndCitations() {
        let prompt = LibraryQuestion.prompt(question: " When? ", sources: [.init(title: "A", passage: "a"), .init(title: "B", passage: "b")])
        XCTAssertEqual(prompt, "Sources:\n\n[1] A\na\n\n[2] B\nb\n\nQuestion: When?")
        XCTAssertEqual(LibraryQuestion.citations(in: "It was March [2], by Ray [1][2] (see [3, 1]) and [9].", sourceCount: 3),
                       [2, 1, 3])
    }
}

final class SealedTests: XCTestCase {
    func testContentsRoundTrip() throws {
        let contents = SealedContents(body: "secret", extractedText: "words", summary: "about", article: Data([1, 2]),
                                      transcript: nil, highlights: [.init(id: UUID(), text: "hi", note: "n")])
        XCTAssertEqual(SealedContents(json: contents.json), contents)
    }

    func testFormatMarksSealedData() {
        let cipher = Data([9, 8, 7])
        let wrapped = SealedFormat.wrap(cipher)
        XCTAssertTrue(SealedFormat.isSealed(wrapped))
        XCTAssertEqual(SealedFormat.unwrap(wrapped), cipher)
        XCTAssertFalse(SealedFormat.isSealed(Data("%PDF-1.4".utf8)))
        XCTAssertNil(SealedFormat.unwrap(Data("STASHSEAL".utf8)))
    }
}
