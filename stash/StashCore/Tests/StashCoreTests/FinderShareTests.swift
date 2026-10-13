import XCTest
@testable import StashCore

final class FinderShareTests: XCTestCase {
    func testUniqueNamesWithinAFolder() {
        let now = Date()
        let entries = [
            FinderEntry(id: "i-1", parent: "root", name: "Notes.md", isFolder: false, created: now, modified: now),
            FinderEntry(id: "i-2", parent: "root", name: "notes.md", isFolder: false, created: now, modified: now),
            FinderEntry(id: "i-3", parent: "c-x", name: "Notes.md", isFolder: false, created: now, modified: now),
            FinderEntry(id: "c-4", parent: "root", name: "Work", isFolder: true, created: now, modified: now),
            FinderEntry(id: "c-5", parent: "root", name: "Work", isFolder: true, created: now, modified: now),
        ]
        XCTAssertEqual(FinderSnapshot.uniquelyNamed(entries).map(\.name), ["Notes.md", "notes 2.md", "Notes.md", "Work", "Work 2"])
        XCTAssertEqual(FinderSnapshot.fileName("a/b: c", ext: "md"), "a-b- c.md")
        XCTAssertEqual(FinderSnapshot.fileName("  ", ext: ""), "Untitled")
    }

    func testSnapshotAndRequestsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let share = FinderShare(root: root)
        XCTAssertEqual(share.snapshot().version, 0)
        let snapshot = FinderSnapshot(version: 3, entries: [
            FinderEntry(id: "c-\(UUID().uuidString)", parent: "root", name: "Work", isFolder: true,
                        created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)),
        ])
        try share.write(snapshot)
        XCTAssertEqual(share.snapshot(), snapshot)
        XCTAssertTrue(snapshot.entries[0].isCategory)
        XCTAssertNotNil(snapshot.entries[0].uuid)

        let file = root.appendingPathComponent("in.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try share.add(FinderRequest(kind: .newFile, name: "in.txt", parent: "root", fileName: "in.txt"), file: file)
        try share.add(FinderRequest(kind: .delete, entryID: "i-x"))
        let pending = share.pending()
        XCTAssertEqual(pending.map(\.request.kind), [.newFile, .delete])
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(pending[0].file), encoding: .utf8), "hello")
        share.remove(pending[0])
        XCTAssertEqual(share.pending().count, 1)
    }

    func testWebloc() throws {
        let data = FinderSnapshot.webloc(for: "https://example.com")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        XCTAssertEqual(plist?["URL"], "https://example.com")
    }
}
