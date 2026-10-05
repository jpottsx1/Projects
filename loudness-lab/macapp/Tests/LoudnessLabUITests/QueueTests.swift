import XCTest
@testable import LoudnessLabUI

/// What the To Process list shows: a host's "these tracks" narrows it, and
/// Clear really empties it.
@MainActor
final class QueueTests: XCTestCase {

    private var folder: URL!
    private var missingDatabase: URL!

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path (/private/var, not the /var link), which is the
        // form a scan reports: a sent file must match what was scanned.
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        folder = URL(fileURLWithPath: realpath(made.path, &buffer) != nil
                     ? String(cString: buffer) : made.path)
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path,
                                           contents: Data([0]))
        }
        missingDatabase = folder.appendingPathComponent("none.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func scanned() async -> Queue {
        let queue = Queue()
        await queue.refresh(folders: [folder], databaseURL: missingDatabase)
        return queue
    }

    func testAScanShowsEveryTrack() async {
        let queue = await scanned()
        XCTAssertEqual(queue.items.count, 3)
    }

    func testAHostsSelectionIsTheWholeList() async {
        let queue = await scanned()
        queue.show(only: [url("a.mp3"), url("c.mp3")])
        XCTAssertEqual(Set(queue.items.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
                       ["a.mp3", "c.mp3"])
        XCTAssertTrue(queue.items.allSatisfy(\.included))
        // a later scan (after a run) keeps the narrowing
        await queue.refresh(folders: [folder], databaseURL: missingDatabase)
        XCTAssertEqual(queue.items.count, 2)
        // a new send replaces it
        queue.show(only: [url("b.mp3")])
        XCTAssertEqual(queue.items.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["b.mp3"])
        // adding a folder by hand lifts it
        queue.showEverything()
        XCTAssertEqual(queue.items.count, 3)
    }

    func testAllAndNoneOnlyReachTheTracksOnShow() async {
        let queue = await scanned()
        queue.show(only: [url("a.mp3")])
        queue.setAll(false)
        XCTAssertTrue(queue.includedPaths.isEmpty)
        queue.showEverything()
        // b and c were never on show, so they were not unticked
        XCTAssertEqual(queue.includedPaths.count, 2)
    }

    func testClearEmptiesTheListIncludingSentFiles() async {
        let queue = await scanned()
        queue.show(only: [url("a.mp3")])
        queue.clearAll()
        XCTAssertTrue(queue.items.isEmpty)
        // with no folders, a refresh must not bring the sent file back
        await queue.refresh(folders: [], databaseURL: missingDatabase)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testAFileOutsideTheFoldersIsAddedAndShown() async {
        let queue = await scanned()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.mp3")
        queue.show(only: [outside])
        XCTAssertEqual(queue.items.map(\.path), [outside.path])
    }
}
