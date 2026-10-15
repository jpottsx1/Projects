import Foundation
import SwiftData
import StashCore

/// One of your own fields, as DEVONthink's custom metadata: a name and a
/// kind. Items keep their values in `Item.customFields`.
@Model
final class FieldDefinition {
    var uuid: UUID = UUID()
    var name: String = ""
    var kindRaw: String = CustomField.Kind.text.rawValue
    /// For a choice: the choices, one per line.
    var choices: String = ""
    /// Where it comes in the side panel and the columns.
    var order: Int = 0
    var createdAt: Date = Date()
    /// For a rollup or formula: how it's worked out (`FieldConfig`, as JSON).
    var config: String = ""

    init(name: String, kind: CustomField.Kind, order: Int) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.order = order
    }

    var kind: CustomField.Kind {
        get { CustomField.Kind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var fieldConfig: FieldConfig {
        get { FieldConfig(json: config) }
        set { config = newValue.json }
    }

    var choiceList: [String] {
        get { choices.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { choices = newValue.joined(separator: "\n") }
    }
}
