import SwiftUI
import StashCore

/// "Remind Me" with the usual times, a custom one, or clearing it.
struct ReminderMenu: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        Menu("Remind Me") {
            let now = Date.now, calendar = Calendar.current
            if let date = ReminderDates.laterToday(now: now, calendar: calendar) {
                button("Later Today", date)
            }
            if let date = ReminderDates.tomorrowMorning(now: now, calendar: calendar) {
                button("Tomorrow Morning", date)
            }
            if let date = ReminderDates.thisWeekend(now: now, calendar: calendar) {
                button("This Weekend", date)
            }
            if let date = ReminderDates.nextWeek(now: now, calendar: calendar) {
                button("Next Week", date)
            }
            Button("Choose a Time…") { library.remindingItems = items }
            if items.contains(where: { $0.remindAt != nil }) {
                Divider()
                Button("Clear Reminder") { library.setReminder(items, at: nil) }
            }
        }
    }

    private func button(_ title: String, _ date: Date) -> some View {
        Button {
            library.setReminder(items, at: date)
        } label: {
            Text(title) + Text("  ") + Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
        }
    }
}

/// Choosing a reminder's day and time.
struct ReminderPicker: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let items: [Item]
    @State private var date: Date

    init(items: [Item]) {
        self.items = items
        let start = items.compactMap(\.remindAt).first
            ?? ReminderDates.tomorrowMorning(now: .now, calendar: .current) ?? .now.addingTimeInterval(86400)
        _date = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Remind Me", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .formStyle(.grouped)
            .navigationTitle(items.count == 1 ? "Remind Me" : "Remind Me About \(items.count) Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        library.setReminder(items, at: date)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 460)
    }
}

/// The bell and time on an item with a reminder; red once it's come round.
struct ReminderBadge: View {
    let date: Date

    var body: some View {
        let due = date <= .now
        Label {
            Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month())
        } icon: {
            Image(systemName: due ? "bell.badge.fill" : "bell")
        }
        .foregroundStyle(due ? .red : .secondary)
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(due ? "Reminder due" : "Reminder")
    }
}
