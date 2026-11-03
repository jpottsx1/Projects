import XCTest
@testable import StashCore

final class ReferenceTests: XCTestCase {
    private let page = """
        <html lang="en"><head><title>Fallback Title</title>
        <meta property="og:title" content="Why Soil Matters">
        <meta property="og:site_name" content="Garden Weekly">
        <meta name="author" content="Ann B. Smith">
        <meta property="article:published_time" content="2024-05-06T10:00:00Z">
        <meta name="description" content="On compost &amp; microbes.">
        <meta property="article:tag" content="soil"><meta property="article:tag" content="compost">
        <link rel="canonical" href="https://garden.example/soil">
        <script type="application/ld+json">{"@type":"NewsArticle","author":[{"name":"Ann B. Smith"},{"name":"Bo Lee"}],
        "publisher":{"name":"Weekly Media"},"datePublished":"2024-05-06"}</script>
        </head><body>...</body></html>
        """

    func testReadingAPage() {
        let reference = Reference.fromHTML(page, url: "https://garden.example/soil?utm=1")
        XCTAssertEqual(reference.title, "Why Soil Matters")
        XCTAssertEqual(reference.authors, ["Ann B. Smith"])
        XCTAssertEqual(reference.siteName, "Garden Weekly")
        XCTAssertEqual(reference.publisher, "Weekly Media")
        XCTAssertEqual(reference.published, "2024-05-06")
        XCTAssertEqual(reference.description, "On compost & microbes.")
        XCTAssertEqual(reference.keywords, ["soil", "compost"])
        XCTAssertEqual(reference.url, "https://garden.example/soil")
        XCTAssertEqual(reference.language, "en")
        XCTAssertEqual(Reference(json: reference.json), reference)
        XCTAssertEqual(Reference.date("2024/5/6"), "2024-05-06")
        XCTAssertEqual(Reference.date("May 2024"), "")
    }

    func testCitations() {
        var reference = Reference()
        reference.title = "Why Soil Matters"
        reference.authors = ["Ann B. Smith", "Bo Lee"]
        reference.siteName = "Garden Weekly"
        reference.published = "2024-05-06"
        reference.url = "https://garden.example/soil"
        reference.accessed = "2026-10-15"
        XCTAssertEqual(reference.citation(.apa), "Smith, A. B., & Lee, B. (2024, May 6). *Why Soil Matters*. Garden Weekly. https://garden.example/soil")
        XCTAssertEqual(reference.citation(.mla), "Smith, Ann B., and Bo Lee. “Why Soil Matters.” *Garden Weekly*, 6 May 2024, garden.example/soil. Accessed 15 Oct. 2026.")
        XCTAssertEqual(reference.citation(.chicago), "Smith, Ann B. and Bo Lee. “Why Soil Matters.” Garden Weekly. May 6, 2024. https://garden.example/soil.")
        XCTAssertTrue(reference.bibTeX(key: "smith2024").hasPrefix("@misc{smith2024,\n  title = {Why Soil Matters}"))
        XCTAssertEqual(Reference().citation(.apa), "Untitled. (n.d.).")
    }

    func testDigest() {
        var reference = Reference()
        reference.authors = ["Ann Smith"]
        reference.published = "2024"
        let text = HighlightDigest.markdown(title: "Soil", sources: [
            .init(title: "Why Soil Matters", reference: reference, link: "stash://item?id=1",
                  highlights: [.init(text: "Compost\nfeeds microbes.", note: "Key point", page: 4)]),
            .init(title: "Empty", reference: Reference(), link: "stash://item?id=2", highlights: []),
        ], style: .apa, date: "15 October 2026")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# Soil")
        XCTAssertTrue(lines.contains("> Compost feeds microbes. (p. 4) [^1]"))
        XCTAssertTrue(lines.contains("Key point"))
        XCTAssertTrue(lines.contains("[^1]: Smith, A. (2024). *Why Soil Matters*. [Open in Stash](stash://item?id=1)"))
        XCTAssertFalse(text.contains("## Empty"))
    }
}
