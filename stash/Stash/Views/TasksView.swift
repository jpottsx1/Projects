import SwiftUI
import StashCore

/// Every checkbox in every note: overdue first, then today, upcoming and
/// undated, or note by note. Ticking one ticks it in its note; choosing
/// one opens the note.
struct TasksView: View {
    @Environment(Library.self) private var library
    @AppStorage("tasksByNote") private var byNote = false
    @AppStorage("tasksShowDone") private var showsDone = false

    var body: some View {
        let _ = library.storeVersion
        let tasks = library.allTasks().filter { showsDone || !$0.task.isDone }
        List {
            if byNote {
                let notes = Dictionary(grouping: tasks, by: \.item.uuid).values
                    .sorted { $0[0].item.displayTitle.localizedStandardCompare($1[0].item.displayTitle) == .orderedAscending }
                ForEach(notes, id: \.first!.item.uuid) { group in
                    Section(group[0].item.displayTitle) {
                        ForEach(group) { row($0, showsNote: false) }
                    }
                }
            } else {
                let grouped = Dictionary(grouping: tasks) { NoteTasks.when($0.task) }
                ForEach(NoteTasks.When.allCases.filter { grouped[$0] != nil }, id: \.self) { when in
                    Section(when.name) {
                        ForEach(sorted(grouped[when] ?? [])) { row($0, showsNote: true) }
                    }
                }
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checklist",
                                       description: Text("Checkboxes in notes (- [ ] like this) appear here. Give one a date with @due(2026-10-20)."))
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Group", selection: $byNote) {
                        Text("By Date").tag(false)
                        Text("By Note").tag(true)
                    }
                    Toggle("Show Done", isOn: $showsDone)
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    /// Soonest first, then by note.
    private func sorted(_ tasks: [Library.NoteTask]) -> [Library.NoteTask] {
        let calendar = Calendar.current
        return tasks.sorted { a, b in
            let first = a.task.due.flatMap(calendar.date(from:)) ?? .distantFuture
            let second = b.task.due.flatMap(calendar.date(from:)) ?? .distantFuture
            if first != second { return first < second }
            return (a.item.displayTitle, a.task.line) < (b.item.displayTitle, b.task.line)
        }
    }

    private func row(_ task: Library.NoteTask, showsNote: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                library.toggleTask(task)
            } label: {
                Image(systemName: task.task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.task.isDone ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.task.isDone ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task.text.isEmpty ? " " : task.task.text)
                    .strikethrough(task.task.isDone)
                    .foregroundStyle(task.task.isDone ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let due = task.task.due, let date = Calendar.current.date(from: due) {
                        Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .foregroundStyle(NoteTasks.when(task.task) == .overdue ? .red : .secondary)
                    }
                    if showsNote {
                        Text(task.item.displayTitle).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { library.selection = task.item }
        .contextMenu {
            Button("Open Note") { library.selection = task.item }
            Divider()
            Button("Due Today") { library.setDue(.now, of: task) }
            Button("Due Tomorrow") { library.setDue(Calendar.current.date(byAdding: .day, value: 1, to: .now), of: task) }
            Button("Due Next Week") { library.setDue(Calendar.current.date(byAdding: .day, value: 7, to: .now), of: task) }
            if task.task.due != nil {
                Button("No Due Date") { library.setDue(nil, of: task) }
            }
        }
    }
}
