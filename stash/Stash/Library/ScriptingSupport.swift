#if os(macOS)
import AppKit
import SwiftData
import StashCore

/// AppleScript, as DEVONthink can be scripted: the dictionary is
/// `Stash.sdef`; these answer for what's in it. Apple events arrive on the
/// main thread, so the library is used straight from here.

// MARK: - Objects

/// An item, as a script sees it.
@objc(StashScriptItem)
final class StashScriptItem: NSObject {
    let item: Item

    init(_ item: Item) {
        self.item = item
    }

    private var library: Library { MainActor.assumeIsolated { StashStore.shared.library } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSApp.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil,
                                   key: "scriptItems", uniqueID: uniqueID)
    }

    @objc var uniqueID: String { MainActor.assumeIsolated { item.uuid.uuidString } }
    @objc var kind: String { MainActor.assumeIsolated { item.kind.rawValue } }
    @objc var url: String { MainActor.assumeIsolated { item.urlString ?? "" } }
    @objc var file: URL? { MainActor.assumeIsolated { library.localFile(for: item) } }
    @objc var tagNames: [String] { MainActor.assumeIsolated { item.sortedTags.map(\.name) } }
    @objc var creationDate: Date { MainActor.assumeIsolated { item.createdAt } }
    @objc var modificationDate: Date { MainActor.assumeIsolated { item.modifiedAt } }
    @objc var locked: Bool { MainActor.assumeIsolated { item.isLocked } }

    @objc var name: String {
        get { MainActor.assumeIsolated { item.displayTitle } }
        set {
            MainActor.assumeIsolated {
                let old = item.title
                item.title = newValue
                library.didEdit(item)
                library.rename(item, from: old)
            }
        }
    }

    @objc var text: String {
        get { MainActor.assumeIsolated { library.isHidden(item) ? "" : (item.isSealed ? library.openSeals[item.uuid]?.body ?? "" : item.body) } }
        set {
            MainActor.assumeIsolated {
                guard !library.isHidden(item) else { return }
                if item.isSealed {
                    library.updateSealed(item) { $0.body = newValue }
                } else {
                    item.body = newValue
                    library.didEdit(item)
                    library.save()
                }
            }
        }
    }

    @objc var categoryPath: String {
        get { MainActor.assumeIsolated { item.category?.path ?? "" } }
        set {
            MainActor.assumeIsolated {
                let wanted = newValue.replacingOccurrences(of: "/", with: " › ").trimmingCharacters(in: .whitespaces)
                let category = library.allCategories().first { $0.path.caseInsensitiveCompare(wanted) == .orderedSame }
                if wanted.isEmpty || category != nil { library.file([item], in: category) }
            }
        }
    }

    @objc var favorite: Bool {
        get { MainActor.assumeIsolated { item.isFavorite } }
        set { MainActor.assumeIsolated { library.setFavorite([item], newValue) } }
    }

    @objc var unread: Bool {
        get { MainActor.assumeIsolated { item.isUnread } }
        set { MainActor.assumeIsolated { library.setUnread([item], newValue) } }
    }

    @objc var label: Int {
        get { MainActor.assumeIsolated { item.labelRaw } }
        set { MainActor.assumeIsolated { library.setLabel([item], ItemLabel(rawValue: newValue) ?? .none) } }
    }

    @objc var rating: Int {
        get { MainActor.assumeIsolated { item.rating } }
        set { MainActor.assumeIsolated { library.setRating([item], max(0, min(newValue, 5))) } }
    }
}

@objc(StashScriptCategory)
final class StashScriptCategory: NSObject {
    let category: ItemCategory

    init(_ category: ItemCategory) {
        self.category = category
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSApp.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil,
                                   key: "scriptCategories", uniqueID: uniqueID)
    }

    @objc var uniqueID: String { MainActor.assumeIsolated { category.uuid.uuidString } }
    @objc var name: String { MainActor.assumeIsolated { category.name } }
    @objc var path: String { MainActor.assumeIsolated { category.path } }
}

@objc(StashScriptTag)
final class StashScriptTag: NSObject {
    @objc let name: String

    init(_ name: String) {
        self.name = name
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSApp.classDescription as? NSScriptClassDescription else { return nil }
        return NSNameSpecifier(containerClassDescription: app, containerSpecifier: nil, key: "scriptTags", name: name)
    }
}

// MARK: - The application's elements

/// The keys scripts ask the application for, answered by its delegate.
extension StashMacAppDelegate {
    static let scriptKeys: Set<String> = ["scriptItems", "scriptCategories", "scriptTags", "scriptSelection", "scriptLibraryName"]

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        Self.scriptKeys.contains(key)
    }

    private var library: Library { MainActor.assumeIsolated { StashStore.shared.library } }

    /// Every item not in the Trash, newest first.
    @objc var scriptItems: [StashScriptItem] {
        MainActor.assumeIsolated { library.find("", limit: .max).map(StashScriptItem.init) }
    }

    @objc func valueInScriptItems(withUniqueID id: String) -> StashScriptItem? {
        MainActor.assumeIsolated {
            UUID(uuidString: id).flatMap { library.items(withIDs: [$0]).first }.map(StashScriptItem.init)
        }
    }

    @objc var scriptCategories: [StashScriptCategory] {
        MainActor.assumeIsolated { library.allCategories().map(StashScriptCategory.init) }
    }

    @objc func valueInScriptCategories(withUniqueID id: String) -> StashScriptCategory? {
        MainActor.assumeIsolated {
            library.allCategories().first { $0.uuid.uuidString == id }.map(StashScriptCategory.init)
        }
    }

    @objc var scriptTags: [StashScriptTag] {
        MainActor.assumeIsolated { library.allTagNames().map(StashScriptTag.init) }
    }

    @objc var scriptSelection: [StashScriptItem] {
        MainActor.assumeIsolated { library.selectedItems.map(StashScriptItem.init) }
    }

    @objc var scriptLibraryName: String {
        MainActor.assumeIsolated { StashStore.shared.current.name }
    }
}

// MARK: - Commands

@objc(StashSearchCommand)
final class StashSearchCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let search = directParameter as? String ?? ""
            let limit = (evaluatedArguments?["limit"] as? Int) ?? 50
            return StashStore.shared.library.find(search, limit: max(1, limit)).map(StashScriptItem.init)
        }
    }
}

@objc(StashCreateNoteCommand)
final class StashCreateNoteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let library = StashStore.shared.library
            let item = library.newNote(titled: evaluatedArguments?["title"] as? String ?? "", text: directParameter as? String ?? "")
            return StashScriptItem(item)
        }
    }
}

@objc(StashSaveLinkCommand)
final class StashSaveLinkCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let text = directParameter as? String, let url = WebAddress.url(from: text) else {
                scriptErrorNumber = errAEParamMissed
                scriptErrorString = "That isn’t a web address."
                return nil
            }
            return StashScriptItem(StashStore.shared.library.addLink(url))
        }
    }
}

@objc(StashImportCommand)
final class StashImportCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let library = StashStore.shared.library
            let files = (directParameter as? [URL]) ?? (directParameter as? URL).map { [$0] } ?? []
            let before = Set(library.find("", limit: .max).map(\.uuid))
            library.importFiles(files)
            return library.find("", limit: .max).filter { !before.contains($0.uuid) }.map(StashScriptItem.init)
        }
    }
}

@objc(StashAddTagsCommand)
final class StashAddTagsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let names = (directParameter as? [String]) ?? (directParameter as? String).map { [$0] } ?? []
            let targets = (evaluatedArguments?["items"] as? [StashScriptItem]) ?? (evaluatedArguments?["items"] as? StashScriptItem).map { [$0] } ?? []
            StashStore.shared.library.addTags(from: names.joined(separator: ","), to: targets.map(\.item))
            return nil
        }
    }
}

@objc(StashShowCommand)
final class StashShowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let target = directParameter as? StashScriptItem ?? (evaluatedReceivers as? StashScriptItem) else { return nil }
            StashStore.shared.library.show(target.item)
            NSApp.activate()
            return nil
        }
    }
}

@objc(StashTodayCommand)
final class StashTodayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            StashScriptItem(StashStore.shared.library.appendToToday(directParameter as? String ?? ""))
        }
    }
}

#endif
