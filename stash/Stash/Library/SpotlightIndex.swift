@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Puts items in the system's Spotlight search, so they can be found from
/// outside the app. Choosing one opens Stash on it (`ContentView` handles
/// `CSSearchableItemActionType`).
///
/// Like the app's own index it's rebuilt from the library after every
/// launch and every burst of changes from iCloud. Edits in between are
/// sent a moment after they stop, not on every keystroke.
@MainActor
final class SpotlightIndex {
    private let index = CSSearchableIndex.default()
    /// Off for the test library and for any library but the main one,
    /// which would otherwise replace the main library's entries.
    private let isEnabled: Bool

    init(enabled: Bool = true) {
        isEnabled = enabled && !StashStore.isTestLibrary
    }
    private var waiting: [UUID: Item] = [:]
    private var flush: Task<Void, Never>?
    /// Spotlight only needs enough to find an item by.
    private static let textLimit = 20_000

    /// Bumped when what's put in Spotlight changes, so it's all sent again once.
    private static let version = 2

    /// Whether Spotlight's copy predates what's indexed now (or this is the
    /// first launch), so it needs everything; otherwise it's kept up by updates.
    var needsRebuild: Bool {
        UserDefaults.standard.integer(forKey: "spotlightIndexVersion") != Self.version
    }

    func replaceAll(with items: [Item]) {
        guard isEnabled else { return }
        UserDefaults.standard.set(Self.version, forKey: "spotlightIndexVersion")
        waiting = [:]
        flush?.cancel()
        let searchable = items.filter { !$0.isTrashed && !$0.isLocked }.map(Self.searchable)
        index.deleteAllSearchableItems { [index] _ in
            index.indexSearchableItems(searchable)
        }
    }

    /// Indexes the item shortly, or removes it if it's in the Trash.
    func update(_ item: Item) {
        guard isEnabled else { return }
        waiting[item.uuid] = item
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.sendWaiting()
        }
    }

    func remove(_ ids: [UUID]) {
        guard isEnabled else { return }
        for id in ids { waiting[id] = nil }
        guard !ids.isEmpty else { return }
        index.deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
    }

    private func sendWaiting() {
        let items = waiting.values.filter { $0.modelContext != nil && !$0.isDeleted }
        waiting = [:]
        // In the Trash or locked: out of Spotlight.
        let (trashed, kept) = (items.filter { $0.isTrashed || $0.isLocked }, items.filter { !$0.isTrashed && !$0.isLocked })
        remove(trashed.map(\.uuid))
        if !kept.isEmpty { index.indexSearchableItems(kept.map(Self.searchable)) }
    }

    private static func searchable(_ item: Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: item.kind == .document ? (item.contentType ?? .data) : .text)
        attributes.title = item.displayTitle
        switch item.kind {
        case .note:
            attributes.contentDescription = String(item.body.prefix(300))
        case .link:
            attributes.contentDescription = item.summary.isEmpty ? item.urlString : item.summary
            attributes.url = item.url
        case .document:
            attributes.contentDescription = item.body.isEmpty ? item.contentType?.localizedDescription : String(item.body.prefix(300))
        }
        attributes.textContent = String((item.body + "\n" + item.extractedText).prefix(textLimit))
        attributes.keywords = item.sortedTags.map(\.name) + [item.category?.name].compactMap { $0 }
        attributes.contentCreationDate = item.createdAt
        attributes.contentModificationDate = item.modifiedAt
        return CSSearchableItem(uniqueIdentifier: item.uuid.uuidString, domainIdentifier: item.kind.rawValue,
                                attributeSet: attributes)
    }
}
