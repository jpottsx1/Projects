import XCTest
@testable import StashCore

final class DatabaseTests: XCTestCase {
    func testRollups() {
        XCTAssertEqual(Rollup.compute(["3", "", "4.5"], kind: .number, function: .sum).0, "7.5")
        XCTAssertEqual(Rollup.compute(["3", "", "4.5"], kind: .number, function: .count).0, "3")
        XCTAssertEqual(Rollup.compute(["3", "", "4.5"], kind: .number, function: .countValues).0, "2")
        XCTAssertEqual(Rollup.compute(["2", "4"], kind: .number, function: .average).0, "3")
        XCTAssertEqual(Rollup.compute(["2026-03-01", "2025-12-31"], kind: .date, function: .earliest).0, "2025-12-31")
        XCTAssertEqual(Rollup.compute(["a", "b", "a"], kind: .text, function: .unique).0, "a, b")
        XCTAssertEqual(Rollup.format(1.0 / 3.0), "0.3333")
        XCTAssertEqual(CustomField.relatedIDs(CustomField.storedRelation([UUID(), UUID()])).count, 2)
        let config = FieldConfig(relation: UUID(), function: .sum, formula: "")
        XCTAssertEqual(FieldConfig(json: config.json), config)
    }

    func testFormulas() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))
        let fields: [String: Formula.Value] = [
            "Price": .number(12.5), "Qty": .number(4), "Name": .text("Pears"), "Done": .bool(false),
            "Due": .date(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))),
        ]
        func run(_ text: String) throws -> Formula.Value {
            try Formula.evaluate(text, field: { fields[$0] }, now: now, calendar: calendar)
        }
        XCTAssertEqual(try run("{Price} * {Qty} + 1"), .number(51))
        XCTAssertEqual(try run("round({Price} / 3, 2)"), .number(4.17))
        XCTAssertEqual(try run("{Name} & \" x\" & {Qty}"), .text("Pears x4"))
        XCTAssertEqual(try run("if({Qty} > 3 and not {Done}, \"bulk\", \"single\")"), .text("bulk"))
        XCTAssertEqual(try run("days({Due}, today())"), .number(5))
        XCTAssertEqual(try run("{Due} - today()"), .number(5))
        XCTAssertEqual(try run("dateAdd({Due}, 3)").stored.0, "2026-10-23")
        XCTAssertEqual(try run("prop(\"Qty\") = 4"), .bool(true))
        XCTAssertEqual(try run("upper({Name})"), .text("PEARS"))
        XCTAssertThrowsError(try run("{Missing} + 1"))
        XCTAssertThrowsError(try run("1 / 0"))
        XCTAssertThrowsError(try run("(1 + 2"))
        XCTAssertThrowsError(try run("nope(1)"))
    }
}
