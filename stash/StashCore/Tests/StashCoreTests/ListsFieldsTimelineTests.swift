import XCTest
@testable import StashCore

final class ListsAndFieldsSearchTests: XCTestCase {
    func testListsAndReadLater() {
        let query = SearchQuery("list:Reading list:\"Gift Ideas\" is:later")
        XCTAssertEqual(query.lists, ["reading", "gift ideas"])
        XCTAssertEqual(query.flags, [.readLater])
        XCTAssertTrue(query.groups.isEmpty)
    }

    func testFieldFiltersOnlyForFieldsThatExist() {
        let query = SearchQuery("Price:>10 status:open https://example.com", fields: ["Price", "Due date"])
        XCTAssertEqual(query.fieldFilters, [.init(name: "Price", value: ">10")])
        // A field name with a space can't be written bare; with _ it can.
        let underscored = SearchQuery("Due_date:<2027", fields: ["Due date"])
        XCTAssertEqual(underscored.fieldFilters, [.init(name: "Due date", value: "<2027")])
        // Not fields: plain words.
        XCTAssertEqual(query.terms.map(\.text).filter { $0.contains(":") }, ["status:open", "https://example.com"])
        let quoted = SearchQuery("Price:\"12\"", fields: ["Price"])
        XCTAssertEqual(quoted.fieldFilters, [.init(name: "Price", value: "12")])
    }

    func testMatchingFieldValues() {
        XCTAssertTrue(CustomField.matches("12.5", kind: .number, filter: ">10"))
        XCTAssertFalse(CustomField.matches("8", kind: .number, filter: ">=10"))
        XCTAssertTrue(CustomField.matches("1,234.50", kind: .number, filter: "1234.5"))
        XCTAssertTrue(CustomField.matches("2026-10-12", kind: .date, filter: "2026-10"))
        XCTAssertTrue(CustomField.matches("2026-10-12", kind: .date, filter: "<2027"))
        XCTAssertFalse(CustomField.matches("2026-10-12", kind: .date, filter: ">2026-11"))
        XCTAssertTrue(CustomField.matches("true", kind: .yesNo, filter: "yes"))
        XCTAssertTrue(CustomField.matches("false", kind: .yesNo, filter: "no"))
        XCTAssertTrue(CustomField.matches("In Progress", kind: .choice, filter: "progress"))
        XCTAssertFalse(CustomField.matches("", kind: .text, filter: "x"))
    }

    func testNumbersAndStorage() {
        XCTAssertEqual(CustomField.number(from: "12,5"), 12.5)
        XCTAssertEqual(CustomField.number(from: "1.234,5"), 1234.5)
        XCTAssertEqual(CustomField.number(from: "£1,200"), 1200)
        let id = UUID()
        XCTAssertEqual(CustomField.decode(CustomField.encode([id: "x", UUID(): ""])), [id: "x"])
        XCTAssertEqual(CustomField.encode([:]), "")
        XCTAssertEqual(CustomField.display("true", kind: .yesNo), "Yes")
    }
}

final class CalendarMonthTests: XCTestCase {
    func testWeeksOfAMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2  // Monday
        // October 2026 starts on a Thursday and has 31 days.
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let weeks = CalendarMonth.weeks(of: october, calendar: calendar)
        XCTAssertEqual(weeks.count, 5)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(weeks[0].prefix(3).compactMap { $0 }.count, 0)
        XCTAssertEqual(weeks[0][3].map { calendar.component(.day, from: $0) }, 1)
        XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
        XCTAssertEqual(CalendarMonth.weekdaySymbols(calendar: calendar).first, "M")
    }

    func testCountsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        let counts = CalendarMonth.counts(of: [day, day.addingTimeInterval(3600), day.addingTimeInterval(86_400)], calendar: calendar)
        XCTAssertEqual(counts[calendar.startOfDay(for: day)], 2)
        XCTAssertEqual(counts.count, 2)
    }
}
