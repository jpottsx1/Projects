import SwiftUI
import SwiftData
import StashCore

/// Notion's calendar view: the items shown, on a month, by a date of your
/// choice -- when they were added or changed, their reminder, or any date
/// field (a formula giving a date too). Drag one to another day to move
/// its reminder or date field there.
struct CalendarLayout: View {
    @Environment(Library.self) private var library
    @Query(sort: \FieldDefinition.order) private var fields: [FieldDefinition]
    let items: [Item]
    let menu: (Item) -> AnyView
    @State private var month = Date.now
    @AppStorage("calendarLayoutSource") private var sourceToken = "created"

    private var calendar: Calendar { .current }

    private var source: Library.CalendarDate {
        switch sourceToken {
        case "modified": .modified
        case "reminder": .reminder
        case "created": .created
        default: UUID(uuidString: sourceToken).map(Library.CalendarDate.field) ?? .created
        }
    }

    var body: some View {
        let dated = items.compactMap { item in library.calendarDate(of: item, by: source, fields: fields).map { (item, $0) } }
        let byDay = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.1) }
        VStack(spacing: 0) {
            header(undated: items.count - dated.count)
            Divider()
            ScrollView {
                grid(byDay.mapValues { $0.map(\.0) })
                    .padding(8)
            }
        }
    }

    private func header(undated: Int) -> some View {
        HStack {
            Button { shift(-1) } label: { Label("Previous Month", systemImage: "chevron.left") }
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .frame(minWidth: 140)
            Button { shift(1) } label: { Label("Next Month", systemImage: "chevron.right") }
            Button("Today") { month = .now }
            Spacer()
            if undated > 0 {
                Text("\(undated) without a date").font(.caption).foregroundStyle(.secondary)
            }
            Picker("By", selection: $sourceToken) {
                Text("Date Added").tag("created")
                Text("Date Changed").tag("modified")
                Text("Reminder").tag("reminder")
                let dateFields = fields.filter { $0.kind == .date || $0.kind == .formula || $0.kind == .rollup }
                if !dateFields.isEmpty { Divider() }
                ForEach(dateFields) { Text($0.name).tag($0.uuid.uuidString) }
            }
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(10)
    }

    private func grid(_ byDay: [Date: [Item]]) -> some View {
        let weeks = CalendarMonth.weeks(of: month, calendar: calendar)
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(CalendarMonth.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                GridRow {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date, items: byDay[calendar.startOfDay(for: date)] ?? [])
                        } else {
                            Color.clear.frame(minHeight: 96)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, items: [Item]) -> some View {
        let isToday = calendar.isDateInToday(date)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(calendar.component(.day, from: date))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            ForEach(items.prefix(4)) { item in
                Text(item.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(library.listSelection.contains(item) ? Color.accentColor.opacity(0.3) : Color.accentColor.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                    .onTapGesture { library.selection = item }
                    .contextMenu { menu(item) }
                    .draggable(item.uuid.uuidString)
            }
            if items.count > 4 {
                Text("\(items.count - 4) more").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { ids, _ in
            let moved = library.items(withIDs: ids.compactMap(UUID.init(uuidString:)))
            for item in moved { library.moveDate(of: item, by: source, to: date) }
            return !moved.isEmpty
        }
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }
}
