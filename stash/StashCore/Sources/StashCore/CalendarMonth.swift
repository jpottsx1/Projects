import Foundation

/// A month as a calendar shows it, for the timeline: weeks of days, with
/// blanks before the first and after the last so each week is full.
public enum CalendarMonth {
    /// The month's weeks, each seven days (nil for a day of another month),
    /// starting on the calendar's first weekday.
    public static func weeks(of month: Date, calendar: Calendar = .current) -> [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let first = interval.start
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for day in days {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// How many of the dates fall on each day, by the day's start.
    public static func counts(of dates: [Date], calendar: Calendar = .current) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for date in dates { counts[calendar.startOfDay(for: date), default: 0] += 1 }
        return counts
    }

    /// Short weekday names in the calendar's order: S M T W T F S.
    public static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}
