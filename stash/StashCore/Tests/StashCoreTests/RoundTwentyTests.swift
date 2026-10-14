import XCTest
@testable import StashCore

final class NoteTaskTests: XCTestCase {
    func testTasks() throws {
        let text = """
            # Week
            - [ ] Call the bank @due(2026-10-20)
              - [x] Find the form
            * [ ] Water plants 📅 2026-10-01
            ```
            - [ ] not a task
            ```
            - plain bullet
            """
        let tasks = NoteTasks.tasks(in: text)
        XCTAssertEqual(tasks.map(\.line), [1, 2, 3])
        XCTAssertEqual(tasks[0].text, "Call the bank")
        XCTAssertEqual(tasks[0].due, DateComponents(year: 2026, month: 10, day: 20))
        XCTAssertTrue(tasks[1].isDone)
        XCTAssertEqual(tasks[2].text, "Water plants")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9)))
        XCTAssertEqual(NoteTasks.when(tasks[0], now: now, calendar: calendar), .upcoming)
        XCTAssertEqual(NoteTasks.when(tasks[1], now: now, calendar: calendar), .done)
        XCTAssertEqual(NoteTasks.when(tasks[2], now: now, calendar: calendar), .overdue)

        let moved = NoteTasks.settingDue(DateComponents(year: 2026, month: 11, day: 2), onLine: 3, in: text)
        XCTAssertEqual(moved.components(separatedBy: "\n")[3], "* [ ] Water plants @due(2026-11-02)")
        XCTAssertEqual(NoteTasks.settingDue(nil, onLine: 1, in: text).components(separatedBy: "\n")[1], "- [ ] Call the bank")
        XCTAssertEqual(NoteTasks.settingDue(nil, onLine: 0, in: text), text)
    }
}

final class BackupRotationTests: XCTestCase {
    func testNamesAndRotation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9, minute: 30)))
        XCTAssertEqual(BackupRotation.fileName(library: "Work", date: date, calendar: calendar), "Stash Backup Work 2026-10-14 0930.zip")
        let names = ["Stash Backup Work 2026-10-12 0930.zip", "Stash Backup Work 2026-10-14 0930.zip",
                     "Stash Backup Work 2026-10-13 0930.zip", "Stash Backup 2026-10-14 0930.zip", "notes.txt",
                     "Stash Backup Work Old 2026-10-14 0930.zip"]
        XCTAssertEqual(BackupRotation.backups(among: names, library: "Work").first, "Stash Backup Work 2026-10-14 0930.zip")
        XCTAssertEqual(BackupRotation.surplus(among: names, library: "Work", keep: 2), ["Stash Backup Work 2026-10-12 0930.zip"])
        XCTAssertEqual(BackupRotation.backups(among: names, library: ""), ["Stash Backup 2026-10-14 0930.zip"])
    }
}

final class PictureGeometryTests: XCTestCase {
    func testFittingAndCropping() throws {
        XCTAssertEqual(PictureGeometry.fitting(width: 4000, height: 3000, maxDimension: 1000).width, 1000)
        XCTAssertEqual(PictureGeometry.fitting(width: 4000, height: 3000, maxDimension: 1000).height, 750)
        XCTAssertEqual(PictureGeometry.fitting(width: 400, height: 300, maxDimension: 1000).width, 400)
        // Dragged right to left, and past the bottom edge.
        let rect = try XCTUnwrap(PictureGeometry.pixelRect(x: 150, y: 50, width: -100, height: 80, shownWidth: 200, shownHeight: 100,
                                                           pixelWidth: 2000, pixelHeight: 1000))
        XCTAssertEqual(rect.x, 500)
        XCTAssertEqual(rect.width, 1000)
        XCTAssertEqual(rect.y, 500)
        XCTAssertEqual(rect.height, 500)
        XCTAssertNil(PictureGeometry.pixelRect(x: 10, y: 10, width: 0, height: 5, shownWidth: 200, shownHeight: 100,
                                              pixelWidth: 2000, pixelHeight: 1000))
    }
}
