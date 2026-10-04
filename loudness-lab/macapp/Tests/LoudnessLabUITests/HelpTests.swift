import XCTest
@testable import LoudnessLabUI

/// The help document renderer. A bullet's marker is two characters wide, so a
/// wrapped bullet is indented two spaces, and the renderer once required
/// three: the wrapped half fell out as a paragraph of its own, in the
/// shipped guide as well as in anything written afterwards.
final class HelpDocumentTests: XCTestCase {

    private func items(_ block: HelpDocument.Block) -> [String]? {
        switch block {
        case .bullets(let items), .numbered(let items): return items
        default: return nil
        }
    }

    func testAWrappedBulletStaysOneItem() throws {
        let doc = HelpDocument("- first line\n  and its wrap\n- second")
        XCTAssertEqual(doc.blocks.count, 1, "the wrap must not become a paragraph")
        XCTAssertEqual(items(doc.blocks[0]), ["first line and its wrap", "second"])
    }

    func testAWrappedNumberedItemStaysOneItem() throws {
        let doc = HelpDocument("1. one\n   wrapped at three\n2. two\n  wrapped at two")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(items(doc.blocks[0]), ["one wrapped at three", "two wrapped at two"])
    }

    func testAnUnindentedLineEndsTheList() throws {
        let doc = HelpDocument("- item\nnot a wrap")
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(items(doc.blocks[0]), ["item"])
    }
}
