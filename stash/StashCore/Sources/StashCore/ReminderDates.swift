import Foundation

/// The times offered when setting a reminder, worked out from now.
public enum ReminderDates {
    /// Mornings start at 9.
    public static let morningHour = 9

    /// Three hours from now, on the hour -- unless that's after 9 in the
    /// evening, when there's no "later today" worth offering.
    public static func laterToday(now: Date, calendar: Calendar) -> Date? {
        guard let later = calendar.date(byAdding: .hour, value: 3, to: now),
              let hour = calendar.dateInterval(of: .hour, for: later)?.start,
              calendar.isDate(hour, inSameDayAs: now),
              calendar.component(.hour, from: hour) < 21 else { return nil }
        return hour
    }

    public static func tomorrowMorning(now: Date, calendar: Calendar) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow)
    }

    /// The coming Saturday morning; next week's, if it's already the weekend.
    public static func thisWeekend(now: Date, calendar: Calendar) -> Date? {
        nextWeekday(7, after: now, calendar: calendar)
    }

    /// The coming Monday morning.
    public static func nextWeek(now: Date, calendar: Calendar) -> Date? {
        nextWeekday(2, after: now, calendar: calendar)
    }

    /// The next `weekday` (1 is Sunday) at 9, strictly after today.
    private static func nextWeekday(_ weekday: Int, after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let days = (weekday - calendar.component(.weekday, from: today) + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: days == 0 ? 7 : days, to: today) else { return nil }
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day)
    }
}
