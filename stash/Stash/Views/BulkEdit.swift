import SwiftUI
import SwiftData
import StashCore

/// Shown instead of an item when several are selected: what they are,
/// and everything that can be done to them at once.
struct BulkEditView: View {
    @Environment(Library.self) private var library
    let items: [Item]
    @State private var tags = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Selected", value: "\(items.count) items")
                let kinds = Dictionary(grouping: items, by: \.kind).map { "\($0.value.count) \($0.key.pluralName.lowercased())" }
                Text(kinds.sorted().joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            if items.allSatisfy(\.isTrashed) {
                Section {
                    Button("Put Back") { library.restore(items) }
                    Button("Delete Immediately", role: .destructive) { library.deleteImmediately(items) }
                }
            } else {
                Section("Tags") {
                    HStack {
                        TextField("Add tags to all", text: $tags)
                            .autocorrectionDisabled()
                            .onSubmit(addTags)
                        Button("Add", action: addTags)
                            .disabled(TagName.split(tags).isEmpty)
                    }
                }
                Section("Change") {
                    BulkActions(items: items)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(items.count) Items")
    }

    private func addTags() {
        library.addTags(from: tags, to: items)
        tags = ""
    }
}

/// Everything that can be done to several items at once, as menu items or
/// buttons.
struct BulkActions: View {
    @Environment(Library.self) private var library
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    let items: [Item]

    var body: some View {
        let allFavorite = items.allSatisfy(\.isFavorite)
        Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") {
            library.setFavorite(items, !allFavorite)
        }
        let anyUnread = items.contains(where: \.isUnread)
        Button(anyUnread ? "Mark as Read" : "Mark as Unread") {
            library.setUnread(items, !anyUnread)
        }
        Menu("File In") {
            Button("No Category") { library.file(items, in: nil) }
            ForEach(categories.filter { $0.parent == nil }.flatMap(\.flattened)) { category in
                Button(category.path) { library.file(items, in: category) }
            }
        }
        Button("Add Tags…") { library.taggingItems = items }
        LabelAndRatingMenus(items: items)
        ReminderMenu(items: items)
        if items.contains(where: \.inInbox) {
            Button("Done (Take Out of Inbox)") { library.markFiled(items) }
        }
        Button("Export…") {
            library.exportRequest = .items(items, name: items.count == 1 ? items[0].displayTitle : "\(items.count) Items")
        }
        Button("Move to Trash", role: .destructive) { library.moveToTrash(items) }
    }
}
