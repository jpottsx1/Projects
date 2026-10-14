import Foundation
import SwiftData
import StashCore

/// The checkboxes in every note, gathered for the Tasks view. They stay in
/// their notes: ticking one here ticks it there.
extension Library {
    struct NoteTask: Identifiable {
        let item: Item
        let task: NoteTasks.Task
        var id: String { item.uuid.uuidString + "-\(task.line)" }
    }

    func allTasks() -> [NoteTask] {
        let note = ItemKind.note.rawValue
        let notes = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate {
            $0.kindRaw == note && $0.trashedAt == nil && !$0.isTemplate && !$0.isLocked
        }))) ?? []
        return notes.filter { CompiledSearch.hasChecklist($0.body) }.flatMap { item in
            NoteTasks.tasks(in: item.body).map { NoteTask(item: item, task: $0) }
        }
    }

    /// Only notes with a due date written in them are read.
    func overdueTaskCount(now: Date) -> Int {
        let note = ItemKind.note.rawValue
        let dated = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate {
            $0.kindRaw == note && $0.trashedAt == nil && !$0.isTemplate && !$0.isLocked
                && ($0.body.contains("@due(") || $0.body.contains("📅"))
        }))) ?? []
        return dated.flatMap { NoteTasks.tasks(in: $0.body) }.filter { NoteTasks.when($0, now: now) == .overdue }.count
    }

    func toggleTask(_ task: NoteTask) {
        task.item.body = MarkdownBlocks.toggleTask(onLine: task.task.line, in: task.item.body)
        didEdit(task.item)
    }

    func setDue(_ day: Date?, of task: NoteTask) {
        let components = day.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
        task.item.body = NoteTasks.settingDue(components, onLine: task.task.line, in: task.item.body)
        didEdit(task.item)
    }
}
