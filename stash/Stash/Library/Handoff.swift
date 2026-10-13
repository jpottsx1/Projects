import Foundation

/// Handoff: the item you're looking at, offered to your other devices
/// signed in to the same iCloud account, which open it where you were.
/// Only items in the main library, the one that syncs: others aren't there.
/// (Handoff needs Stash signed with a developer team on each device.)
extension Library {
    static let handoffActivityType = "com.jpottsx1.stash.item"

    /// The item to offer for Handoff, if there is one.
    var handoffItem: Item? {
        guard isMain, let selection, !selection.isTrashed, !isHidden(selection), !selection.isTemplate else { return nil }
        return selection
    }

    func describe(_ item: Item, in activity: NSUserActivity) {
        activity.title = item.displayTitle
        activity.userInfo = ["id": item.uuid.uuidString]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        // A link can be picked up in a browser where Stash isn't installed.
        if item.kind == .link, let url = item.url, ["http", "https"].contains(url.scheme ?? "") {
            activity.webpageURL = url
        }
    }

    /// Opens an item handed off from another device.
    static func continueActivity(_ activity: NSUserActivity) {
        guard let id = (activity.userInfo?["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let store = StashStore.shared
        if !store.current.isMain, let main = store.libraries.first(where: \.isMain) { store.switchTo(main) }
        let library = store.library
        if let item = library.items(withIDs: [id]).first {
            library.show(item)
        } else {
            library.importError = "“\(activity.title ?? "That item")” isn’t on this device yet. It appears once iCloud has brought it over."
        }
    }
}
