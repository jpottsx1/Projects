import Foundation
import SwiftData
import SwiftUI
import StashCore

/// Aliases, and DEVONthink's automatic wiki links.
extension Library {
    static let autoLinkKey = "autoLinkNames"

    func setAliases(_ text: String, of item: Item) {
        item.aliases = text
        save()
        reindex(item)
        revision += 1
    }

    /// Every item's title and aliases, to link where they're mentioned
    /// in `note`'s preview: not its own, nor templates or the Trash.
    func autoLinkNames(excluding note: Item) -> [AutoLink.Name] {
        let names: [AutoLink.Name]
        if let cache = autoLinkCache, cache.version == storeVersion {
            names = cache.names
        } else {
            let items = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).filter { !$0.isTrashed && !$0.isTemplate }
            names = items.flatMap { item in
                ([item.title] + Aliases.split(item.aliases)).filter { !$0.isEmpty }
                    .map { AutoLink.Name(name: $0, title: item.title) }
            }
            autoLinkCache = (storeVersion, names)
        }
        let own = Set(([note.title] + Aliases.split(note.aliases)).map(WikiLinks.key))
        return names.filter { !own.contains(WikiLinks.key($0.title)) }
    }
}

/// Turns automatic links on and off.
struct AutoLinkToggle: View {
    @AppStorage(Library.autoLinkKey) private var isOn = false

    var body: some View {
        Toggle("Link Item Names Automatically", isOn: $isOn)
            .help("In a note's preview, link the first mention of any item's title or alias")
    }
}
