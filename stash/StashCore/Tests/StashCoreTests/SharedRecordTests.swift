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

final class SharedMergeTests: XCTestCase {
    func testSignatures() {
        var payload = SharedItemPayload(kind: "note", title: "A", body: "x", extractedText: "read",
                                        createdAt: .distantPast, modifiedAt: Date(timeIntervalSince1970: 10))
        let first = payload.signature
        payload.extractedText = "read again"
        XCTAssertEqual(payload.signature, first)
        payload.body = "y"
        XCTAssertNotEqual(payload.signature, first)
    }

    func testDecisions() {
        let early = Date(timeIntervalSince1970: 1), late = Date(timeIntervalSince1970: 2)
        // Our own change coming back.
        XCTAssertEqual(SharedMerge.decide(incoming: "b", incomingModified: late, sent: "b", local: "b", localModified: late), .ignore)
        // New to us.
        XCTAssertEqual(SharedMerge.decide(incoming: "b", incomingModified: late, sent: nil, local: nil, localModified: nil), .apply)
        // Changed there, not here.
        XCTAssertEqual(SharedMerge.decide(incoming: "c", incomingModified: late, sent: "a", local: "a", localModified: early), .apply)
        // Changed in both places: the later wins.
        XCTAssertEqual(SharedMerge.decide(incoming: "c", incomingModified: early, sent: "a", local: "b", localModified: late), .keepLocal)
        XCTAssertEqual(SharedMerge.decide(incoming: "c", incomingModified: late, sent: "a", local: "b", localModified: early), .apply)
    }
}
