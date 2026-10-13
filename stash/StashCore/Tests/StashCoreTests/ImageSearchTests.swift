import XCTest
@testable import StashCore

final class ImageSearchTests: XCTestCase {
    func testSearchAddresses() throws {
        let address = "https://example.com/pics/a cat.jpg?size=big&x=1"
        let lens = try XCTUnwrap(ImageSearch.Engine.googleLens.searchURL(forImageAt: address))
        XCTAssertEqual(lens.host, "lens.google.com")
        // The image's address arrives whole, as one parameter.
        let value = URLComponents(url: lens, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
        XCTAssertEqual(value, "https://example.com/pics/a%20cat.jpg?size=big&x=1")
        XCTAssertEqual(ImageSearch.Engine.tinEye.searchURL(forImageAt: address)?.host, "tineye.com")
        XCTAssertTrue(try XCTUnwrap(ImageSearch.Engine.bing.searchURL(forImageAt: address)).absoluteString.contains("imgurl:https%3A%2F%2F"))
        // Files on this device can't be searched by address.
        XCTAssertNil(ImageSearch.Engine.yandex.searchURL(forImageAt: "file:///Users/me/cat.jpg"))
        XCTAssertNil(ImageSearch.Engine.yandex.searchURL(forImageAt: "/Users/me/cat.jpg"))
    }

    func testImageAddressesAndWhereFrom() throws {
        XCTAssertTrue(ImageSearch.isImageAddress("https://example.com/a/b.PNG"))
        XCTAssertFalse(ImageSearch.isImageAddress("https://example.com/article"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["https://cdn.example.com/x.jpg", "https://example.com/page"],
                                                       format: .binary, options: 0)
        XCTAssertEqual(ImageSearch.whereFrom(plist), "https://cdn.example.com/x.jpg")
        let local = try PropertyListSerialization.data(fromPropertyList: ["x-apple-data:abc"], format: .binary, options: 0)
        XCTAssertNil(ImageSearch.whereFrom(local))
    }
}
