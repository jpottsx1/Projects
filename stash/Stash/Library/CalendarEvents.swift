import EventKit
import Foundation
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The calendars on this device, read with EventKit: the day's events for
/// daily notes, and events to make notes for or link items to.
@MainActor
final class CalendarEvents {
    static let shared = CalendarEvents()
    let store = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asked for the first time it's wanted.
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    func events(on day: Date, calendar: Calendar = .current) -> [EKEvent] {
        let start = calendar.startOfDay(for: day)
        return events(from: start, to: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    func event(withID id: String) -> EKEvent? {
        guard isAuthorized, !id.isEmpty else { return nil }
        return store.event(withIdentifier: id)
    }

    /// "09:30–10:00 Standup (Room 2)", or "All day: Holiday".
    static func line(for event: EKEvent) -> String {
        let title = event.title ?? "Untitled"
        let place = event.location.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        if event.isAllDay { return "All day: " + title + place }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end) \(title)\(place)"
    }

    /// The day's events as Markdown list items, for `{{events}}`.
    func markdownList(on day: Date) -> String {
        events(on: day).map { "- " + Self.line(for: $0) }.joined(separator: "\n")
    }

    /// Opens the event in Calendar.
    static func show(_ event: EKEvent) {
        #if os(macOS)
        if let url = URL(string: "ical://ekevent/\(event.calendarItemIdentifier)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: "calshow:\(event.startDate.timeIntervalSinceReferenceDate)") {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

extension Library {
    /// Whether daily notes list the day's events.
    static var dailyNotesShowEvents: Bool {
        get { UserDefaults.standard.bool(forKey: "dailyNotesShowEvents") }
        set { UserDefaults.standard.set(newValue, forKey: "dailyNotesShowEvents") }
    }

    /// The text a daily note starts with when there's no template.
    static var defaultDailyBody: String {
        dailyNotesShowEvents ? "## Today\n\n{{events}}\n\n## Notes\n\n" : ""
    }

    /// A note about a calendar event: when, where and with whom, linked to it.
    @discardableResult
    func newNote(for event: EKEvent) -> Item {
        var lines = ["**When:** " + event.startDate.formatted(date: .complete, time: event.isAllDay ? .omitted : .shortened)]
        if let location = event.location, !location.isEmpty { lines.append("**Where:** " + location) }
        let people = (event.attendees ?? []).compactMap(\.name).filter { !$0.isEmpty }
        if !people.isEmpty { lines.append("**With:** " + people.joined(separator: ", ")) }
        if let notes = event.notes, !notes.isEmpty { lines.append("\n" + notes) }
        let note = newNote(titled: event.title ?? "Meeting", text: lines.joined(separator: "  \n") + "\n\n## Notes\n\n")
        link(note, to: event)
        return note
    }

    func link(_ item: Item, to event: EKEvent?) {
        item.calendarEventID = event?.eventIdentifier ?? ""
        item.calendarEventTitle = event?.title ?? ""
        item.calendarEventStart = event?.startDate
        save()
    }
}
