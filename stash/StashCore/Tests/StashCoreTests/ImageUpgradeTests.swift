import XCTest
@testable import StashCore

final class ImageUpgradeTests: XCTestCase {
    func testRewrites() {
        func first(_ address: String) -> String? { ImageUpgrade.rewrites(of: address).first }
        XCTAssertEqual(first("https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Cat.jpg/220px-Cat.jpg"),
                       "https://upload.wikimedia.org/wikipedia/commons/a/ab/Cat.jpg")
        XCTAssertEqual(first("https://i.pinimg.com/236x/12/34/56/abc.jpg"), "https://i.pinimg.com/originals/12/34/56/abc.jpg")
        XCTAssertEqual(first("https://pbs.twimg.com/media/Abc?format=jpg&name=small"), "https://pbs.twimg.com/media/Abc?format=jpg&name=orig")
        XCTAssertEqual(first("https://i.imgur.com/AbCdEfGm.jpg"), "https://i.imgur.com/AbCdEfG.jpg")
        XCTAssertEqual(first("https://example.com/wp-content/uploads/2024/05/photo-300x200.jpg"),
                       "https://example.com/wp-content/uploads/2024/05/photo.jpg")
        XCTAssertEqual(first("https://m.media-amazon.com/images/I/81abc._AC_SX300_SY300_.jpg"), "https://m.media-amazon.com/images/I/81abc.jpg")
        XCTAssertEqual(first("https://preview.redd.it/abc.jpg?width=640&auto=webp"), "https://i.redd.it/abc.jpg")
        XCTAssertEqual(first("https://res.cloudinary.com/demo/image/upload/w_300,h_200,c_fill/sample.jpg"),
                       "https://res.cloudinary.com/demo/image/upload/sample.jpg")
        XCTAssertEqual(first("https://images.unsplash.com/photo-1?w=400&q=80&fm=jpg"), "https://images.unsplash.com/photo-1")
        XCTAssertTrue(ImageUpgrade.rewrites(of: "https://example.com/plain.jpg").isEmpty)
    }

    func testFromThePage() {
        let html = """
            <a href="/full/cat.jpg"><img src="/thumbs/cat.jpg" srcset="/thumbs/cat.jpg 300w, /big/cat.jpg 1200w, /mid/cat.jpg 800w"></a>
            <img src="/other.jpg" data-large-file="/other-large.jpg">
            """
        let candidates = ImageUpgrade.candidates(for: "https://site.example/thumbs/cat.jpg", html: html, base: "https://site.example/post")
        XCTAssertEqual(candidates.first, "https://site.example/big/cat.jpg")
        XCTAssertTrue(candidates.contains("https://site.example/full/cat.jpg"))
        XCTAssertEqual(candidates.last, "https://site.example/thumbs/cat.jpg")
        XCTAssertFalse(candidates.contains("https://site.example/other-large.jpg"))
        XCTAssertEqual(ImageUpgrade.srcset("a.jpg 1x, b.jpg 2x").map(\.size), [1000, 2000])
    }
}
