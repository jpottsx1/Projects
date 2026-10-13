import Foundation
import SwiftData
import StashCore

/// Something to do to items as they arrive: when one matches the search,
/// file it, tag it, label it, rate it, star it, mark it read or done.
///
/// Rules run on the device an item arrives on -- added, imported, shared,
/// scanned or saved by Shortcuts -- once when it arrives and again once its
/// page or document has been read, so they can match words inside it.
/// Items arriving by iCloud were already dealt with where they came from.
@Model
final class SmartRule {
    var uuid: UUID = UUID()
    var name: String = ""
    /// Search syntax, as in the search field; empty matches everything.
    var query: String = ""
    var isEnabled: Bool = true
    var createdAt: Date = Date()

    // What to do. Each is left alone unless set.
    var category: ItemCategory?
    /// Comma-separated, as typed.
    var tagsToAdd: String = ""
    /// An `ItemLabel`'s raw value, or -1 to leave it.
    var labelRaw: Int = -1
    /// 0 to 5, or -1 to leave it.
    var rating: Int = -1
    var makesFavorite: Bool = false
    var marksRead: Bool = false
    var takesOutOfInbox: Bool = false

    // When else it runs, over everything already here that matches.
    /// A `RuleSchedule`'s raw value.
    var scheduleRaw: String = RuleSchedule.never.rawValue
    var runsAtLaunch: Bool = false
    var lastRunAt: Date?

    var schedule: RuleSchedule {
        get { RuleSchedule(rawValue: scheduleRaw) ?? .never }
        set { scheduleRaw = newValue.rawValue }
    }

    init(name: String) {
        self.name = name
    }

    /// "File in Work · #invoice · Red" -- what it does, in a few words.
    var summary: String {
        var parts: [String] = []
        if let category { parts.append("File in \(category.name)") }
        parts += TagName.split(tagsToAdd).map { "#" + $0 }
        if labelRaw >= 0, let label = ItemLabel(rawValue: labelRaw) {
            parts.append(label == .none ? "No label" : label.name)
        }
        if rating >= 0 { parts.append(rating == 0 ? "Unrated" : String(repeating: "★", count: rating)) }
        if makesFavorite { parts.append("Favorite") }
        if marksRead { parts.append("Read") }
        if takesOutOfInbox { parts.append("Done") }
        return parts.isEmpty ? "Does nothing yet" : parts.joined(separator: " · ")
    }
}
