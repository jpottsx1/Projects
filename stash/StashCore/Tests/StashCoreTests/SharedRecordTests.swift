import XCTest
@testable import StashCore

final class SharedRecordTests: XCTestCase {
    func testPayloadRoundTrip() throws {
        let payload = SharedItemPayload(
            kind: "note", title: "Soup", body: "Leeks", createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 100), tags: ["food"], folders: ["Winter"],
            highlights: [.init(id: UUID(), text: "Leeks", note: "", color: "yellow", customColor: "", anchor: "{}",
                               position: 0.5, createdAt: Date(timeIntervalSince1970: 50))])
        XCTAssertEqual(try SharedItemPayload.decode(payload.encoded()), payload)
        let long = SharedItemPayload(kind: "document", title: "Big", extractedText: String(repeating: "a", count: 300_000),
                                     createdAt: .distantPast, modifiedAt: .distantPast)
        XCTAssertEqual(long.extractedText.count, SharedItemPayload.textLimit)
    }

    func testZonesAndChanges() {
        let id = UUID()
        XCTAssertEqual(SharedZones.categoryID(fromZone: SharedZones.zoneName(forCategory: id)), id)
        XCTAssertNil(SharedZones.categoryID(fromZone: "com.apple.coredata.cloudkit.zone"))
        let a = UUID(), b = UUID(), c = UUID()
        let changes = SharedZones.changes(now: [a: "1", b: "2"], sent: [a: "1", b: "1", c: "1"])
        XCTAssertEqual(changes.save, [b])
        XCTAssertEqual(changes.delete, [c])
    }
}
