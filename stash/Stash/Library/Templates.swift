import Foundation
import SwiftData
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Templates, and the day's note made from one.
///
/// A template is a note kept in Templates rather than with the others.
/// Making a note from it fills in its placeholders (see `NoteTemplate`)
/// and brings along its pictures, tags and category.
extension Library {
    /// Templates, by name.
    func templates() -> [Item] {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.isTemplate && $0.trashedAt == nil },
                                               sortBy: [SortDescriptor(\.title)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func newNote(from template: Item, title: String? = nil) -> Item {
        var values = NoteTemplate.Values()
        // Reading the clipboard asks permission on an iPhone, so only when it's wanted.
        if (template.title + template.body).range(of: "{{clipboard", options: .caseInsensitive) != nil {
            values.clipboard = Self.clipboardText() ?? ""
        }
        if template.body.range(of: "{{events", options: .caseInsensitive) != nil {
            values.events = Self.eventsText(on: values.date)
        }
        let filledTitle = title ?? NoteTemplate.fill(template.title, with: values)
        values.title = filledTitle
        // A note made here isn't a template, whichever list is showing.
        if sidebar == .templates { sidebar = .all }

        let item = Item(kind: .note, title: filledTitle)
        item.body = NoteTemplate.fill(template.body, with: values)
        insert(item)
        for attachment in template.attachments ?? [] {
            guard let data = attachment.data else { continue }
            let copy = NoteAttachment(fileName: attachment.fileName, data: data)
            context.insert(copy)
            copy.item = item
            try? files.write(data, to: "\(item.uuid.uuidString)/Attachments/\(attachment.fileName)")
        }
        if let category = template.category {
            item.category = category
            item.inInbox = false
        }
        for tag in template.tags ?? [] where !(item.tags ?? []).contains(tag) {
            item.tags = (item.tags ?? []) + [tag]
        }
        save()
        reindex(item)
        return item
    }

    /// A template made from a copy of a note, which is left as it was.
    @discardableResult
    func saveAsTemplate(_ note: Item) -> Item {
        let template = Item(kind: .note, title: note.title)
        template.body = note.body
        template.isTemplate = true
        context.insert(template)
        template.category = note.category
        template.tags = note.tags
        for attachment in note.attachments ?? [] {
            guard let data = attachment.data else { continue }
            let copy = NoteAttachment(fileName: attachment.fileName, data: data)
            context.insert(copy)
            copy.item = template
            try? files.write(data, to: "\(template.uuid.uuidString)/Attachments/\(attachment.fileName)")
        }
        save()
        reindex(template)
        sidebar = .templates
        selection = template
        return template
    }

    // MARK: - Daily notes

    /// How daily notes are titled: a `DateFormatter` format.
    static var dailyTitleFormat: String {
        get { UserDefaults.standard.string(forKey: "dailyNoteFormat").flatMap { $0.isEmpty ? nil : $0 } ?? NoteTemplate.dailyTitleFormat }
        set { UserDefaults.standard.set(newValue, forKey: "dailyNoteFormat") }
    }

    static let dailyCategoryName = "Daily Notes"

    /// The template daily notes are made from; nil for a plain note.
    var dailyTemplate: Item? {
        get {
            guard let id = UserDefaults.standard.string(forKey: "dailyNoteTemplate").flatMap(UUID.init(uuidString:)) else { return nil }
            return items(withIDs: [id]).first { $0.isTemplate && !$0.isTrashed }
        }
        set { UserDefaults.standard.set(newValue?.uuid.uuidString, forKey: "dailyNoteTemplate") }
    }

    /// Adds text to the end of today's note (made if need be): a line of
    /// its own, or a list item.
    @discardableResult
    func appendToToday(_ text: String, asListItem: Bool = false) -> Item {
        let note = openToday()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return note }
        let addition = asListItem ? trimmed.split(separator: "\n").map { "- " + $0 }.joined(separator: "\n") : trimmed
        note.body = note.body.isEmpty ? addition
            : note.body.trimmingCharacters(in: .newlines) + (asListItem ? "\n" : "\n\n") + addition
        didEdit(note)
        save()
        return note
    }

    /// Today's note, made if there isn't one yet, and shown.
    @discardableResult
    func openToday() -> Item {
        let title = NoteTemplate.format(.now, Self.dailyTitleFormat, NoteTemplate.Values())
        let kind = ItemKind.note.rawValue
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate {
            $0.title == title && $0.kindRaw == kind && !$0.isTemplate && $0.trashedAt == nil
        })
        // Two devices may each have made one before they synced: always the same one.
        if let existing = ((try? context.fetch(descriptor)) ?? []).min(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            show(existing)
            return existing
        }
        if sidebar == .templates { sidebar = .all }
        let note: Item
        if let template = dailyTemplate {
            note = newNote(from: template, title: title)
        } else {
            var values = NoteTemplate.Values(title: title)
            values.events = Self.eventsText(on: .now)
            note = newNote(titled: title, text: NoteTemplate.fill(Self.defaultDailyBody, with: values))
        }
        if note.category == nil {
            note.category = dailyCategory()
            note.inInbox = false
        }
        save()
        show(note)
        return note
    }

    /// The Daily Notes category, made the first time.
    private func dailyCategory() -> ItemCategory? {
        let name = Self.dailyCategoryName
        let descriptor = FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.name == name && $0.parent == nil })
        if let existing = ((try? context.fetch(descriptor)) ?? []).min(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            return existing
        }
        return newCategory(named: name)
    }

    /// The day's events as a list, for `{{events}}`; a line saying why when there are none to show.
    static func eventsText(on day: Date) -> String {
        guard CalendarEvents.shared.isAuthorized else { return "_Calendar access is off._" }
        let list = CalendarEvents.shared.markdownList(on: day)
        return list.isEmpty ? "_No events._" : list
    }

    static func clipboardText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
