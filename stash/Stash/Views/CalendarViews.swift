import EventKit
import SwiftUI

/// What an event's been picked for.
enum EventPicking: Identifiable {
    /// A new note about it.
    case newNote
    /// Linking an item to it.
    case link(Item)

    var id: String {
        switch self {
        case .newNote: "new"
        case .link(let item): item.uuid.uuidString
        }
    }
}

/// Events from yesterday to a week ahead, to make a note for or link to.
struct EventPickerView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let purpose: EventPicking
    @State private var events: [EKEvent] = []
    @State private var allowed: Bool?

    var body: some View {
        NavigationStack {
            Group {
                if allowed == false {
                    ContentUnavailableView("No Calendar Access", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("Allow Stash to read your calendars in Settings › Privacy & Security › Calendars."))
                } else if allowed == nil {
                    ProgressView()
                } else if events.isEmpty {
                    ContentUnavailableView("No Events", systemImage: "calendar",
                                           description: Text("Nothing from yesterday to a week from now."))
                } else {
                    List {
                        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.startDate) }
                        ForEach(days.keys.sorted(), id: \.self) { day in
                            Section(day.formatted(date: .complete, time: .omitted)) {
                                ForEach(days[day] ?? [], id: \.eventIdentifier) { event in
                                    Button {
                                        choose(event)
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(Color(cgColor: event.calendar.cgColor))
                                                .frame(width: 8, height: 8)
                                            Text(CalendarEvents.line(for: event))
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNewNote ? "Note for Event" : "Link to Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheetSize(minWidth: 420, minHeight: 440)
        .task {
            let calendars = CalendarEvents.shared
            allowed = await calendars.requestAccess()
            let today = Calendar.current.startOfDay(for: .now)
            events = calendars.events(from: today.addingTimeInterval(-86_400), to: today.addingTimeInterval(8 * 86_400))
        }
    }

    private var isNewNote: Bool {
        if case .newNote = purpose { return true }
        return false
    }

    private func choose(_ event: EKEvent) {
        switch purpose {
        case .newNote: library.newNote(for: event)
        case .link(let item): library.link(item, to: event)
        }
        dismiss()
    }
}

/// An item's calendar event, in the side panel.
struct CalendarSection: View {
    @Environment(Library.self) private var library
    let item: Item

    var body: some View {
        Section {
            if item.calendarEventID.isEmpty {
                Button("Link to Event…") { library.eventPicking = .link(item) }
                    .buttonStyle(.borderless)
            } else {
                LabeledContent(item.calendarEventTitle.isEmpty ? "Event" : item.calendarEventTitle) {
                    if let start = item.calendarEventStart {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                HStack {
                    if let event = CalendarEvents.shared.event(withID: item.calendarEventID) {
                        Button("Open in Calendar") { CalendarEvents.show(event) }
                    }
                    Spacer()
                    Button("Unlink") { library.link(item, to: nil) }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Calendar")
        }
    }
}

/// Daily notes listing the day's events: on, it asks for calendar access.
struct DailyEventsToggle: View {
    @AppStorage("dailyNotesShowEvents") private var showEvents = false

    var body: some View {
        Toggle("Daily Notes List the Day’s Events", isOn: Binding(get: { showEvents }, set: { on in
            showEvents = on
            if on { Task { showEvents = await CalendarEvents.shared.requestAccess() } }
        }))
    }
}
