import Foundation
import SwiftData
import StashCore

/// DEVONthink's workspaces: what the window shows -- the sidebar place,
/// the search, the tag filter, the view and sort, and the item open --
/// saved under a name to come back to. Kept on this device, per library.
struct Workspace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sidebar: String
    var search: String
    var tagFilter: [String]
    var layout: String
    var sort: String
    var ascending: Bool
    var selection: UUID?
}

extension Library {
    private var workspacesKey: String { "workspaces-" + supportFolder.lastPathComponent }

    var workspaces: [Workspace] {
        get {
            UserDefaults.standard.data(forKey: workspacesKey)
                .flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: workspacesKey)
            revision += 1
        }
    }

    /// Saves what's showing, replacing a workspace of the same name.
    func saveWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let workspace = Workspace(name: trimmed, sidebar: Self.token(for: sidebar ?? .all), search: searchText,
                                  tagFilter: tagFilter, layout: layout.rawValue, sort: sort.rawValue,
                                  ascending: sortAscending, selection: selection?.uuid)
        var all = workspaces.filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        all.append(workspace)
        workspaces = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func open(_ workspace: Workspace) {
        sidebar = selection(for: workspace.sidebar) ?? .all
        searchText = workspace.search
        tagFilter = workspace.tagFilter
        isShowingTagFilter = !workspace.tagFilter.isEmpty
        if let layout = ItemLayout(rawValue: workspace.layout) { self.layout = layout }
        if let sort = ItemSort(rawValue: workspace.sort) { self.sort = sort }
        sortAscending = workspace.ascending
        selection = workspace.selection.flatMap { items(withIDs: [$0]).first }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        workspaces = workspaces.filter { $0.id != workspace.id }
    }

    func renameWorkspace(_ workspace: Workspace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaces = workspaces.map { $0.id == workspace.id ? Workspace(id: $0.id, name: trimmed, sidebar: $0.sidebar, search: $0.search,
                                                                         tagFilter: $0.tagFilter, layout: $0.layout, sort: $0.sort,
                                                                         ascending: $0.ascending, selection: $0.selection) : $0 }
    }

    // MARK: - Sidebar places as text

    static func token(for selection: SidebarSelection) -> String {
        switch selection {
        case .inbox: "inbox"
        case .all: "all"
        case .favorites: "favorites"
        case .recents: "recents"
        case .unfiled: "unfiled"
        case .tasks: "tasks"
        case .notebook(let notebook): "notebook:" + notebook.uuid.uuidString
        case .reminders: "reminders"
        case .duplicates: "duplicates"
        case .trash: "trash"
        case .templates: "templates"
        case .readLater: "readLater"
        case .timeline: "timeline"
        case .kind(let kind): "kind:" + kind.rawValue
        case .category(let category): "category:" + category.uuid.uuidString
        case .tag(let tag): "tag:" + tag.uuid.uuidString
        case .smartFilter(let filter): "smartFilter:" + filter.uuid.uuidString
        case .feed(let feed): "feed:" + feed.uuid.uuidString
        case .list(let list): "list:" + list.uuid.uuidString
        }
    }

    func selection(for token: String) -> SidebarSelection? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count == 2 ? UUID(uuidString: parts[1]) : nil
        func first<Model: PersistentModel>(_ type: Model.Type, _ predicate: Predicate<Model>) -> Model? {
            var descriptor = FetchDescriptor<Model>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        switch parts.first ?? "" {
        case "inbox": return .inbox
        case "all": return .all
        case "favorites": return .favorites
        case "recents": return .recents
        case "unfiled": return .unfiled
        case "tasks": return .tasks
        case "reminders": return .reminders
        case "duplicates": return .duplicates
        case "trash": return .trash
        case "templates": return .templates
        case "readLater": return .readLater
        case "timeline": return .timeline
        case "kind": return parts.count == 2 ? ItemKind(rawValue: parts[1]).map(SidebarSelection.kind) : nil
        case "category":
            guard let id else { return nil }
            return first(ItemCategory.self, #Predicate { $0.uuid == id }).map(SidebarSelection.category)
        case "tag":
            guard let id else { return nil }
            return first(Tag.self, #Predicate { $0.uuid == id }).map(SidebarSelection.tag)
        case "smartFilter":
            guard let id else { return nil }
            return first(SmartFilter.self, #Predicate { $0.uuid == id }).map(SidebarSelection.smartFilter)
        case "feed":
            guard let id else { return nil }
            return first(Feed.self, #Predicate { $0.uuid == id }).map(SidebarSelection.feed)
        case "notebook":
            guard let id else { return nil }
            return first(Notebook.self, #Predicate { $0.uuid == id }).map(SidebarSelection.notebook)
        case "list":
            guard let id else { return nil }
            return first(ItemList.self, #Predicate { $0.uuid == id }).map(SidebarSelection.list)
        default: return nil
        }
    }
}
