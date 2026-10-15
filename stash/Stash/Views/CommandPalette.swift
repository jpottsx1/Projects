import SwiftUI
import StashCore

/// Every command, by typing a little of its name (Shift-Cmd-P), with its
/// keyboard shortcut beside it where it has one.
struct CommandPalette: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let title: String
        var shortcut = ""
        var icon = "command"
        let action: () -> Void
        var id: String { title }
    }

    var body: some View {
        let commands = matches
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Run a command…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(commands) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(commands.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: text) { highlighted = 0 }
                    .accessibilityIdentifier("commandPaletteField")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button {
                            dismiss()
                            command.action()
                        } label: {
                            HStack {
                                Image(systemName: command.icon).foregroundStyle(.tint).frame(width: 20)
                                Text(command.title).lineLimit(1)
                                Spacer()
                                Text(command.shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
        .sheetSize(minWidth: 560, minHeight: 420)
        .onAppear { focused = true }
    }

    private func run(_ commands: [Command]) {
        guard commands.indices.contains(highlighted) else { return }
        dismiss()
        commands[highlighted].action()
    }

    private var matches: [Command] {
        let all = Self.commands(for: library)
        return text.isEmpty ? all : QuickOpen.rank(all, query: text, name: \.title)
    }

    static func commands(for library: Library) -> [Command] {
        var commands: [Command] = [
            Command(title: "New Note", shortcut: "⌘N", icon: "square.and.pencil") { library.newNote() },
            Command(title: "Today’s Note", shortcut: "⌘0", icon: "calendar") { library.openToday() },
            Command(title: "New Voice Note", shortcut: "⌥⌘N", icon: "mic") { library.isRecording = true },
            Command(title: "New Mind Map", icon: "point.3.connected.trianglepath.dotted") { library.newMindMap() },
            Command(title: "New Sheet", icon: "tablecells") { library.newSheet() },
            Command(title: "Add Link…", shortcut: "⌘L", icon: "link.badge.plus") { library.isAddingLink = true },
            Command(title: "Import Documents…", shortcut: "⌥⌘I", icon: "doc.badge.plus") { library.isImporting = true },
            Command(title: "Quick Open…", shortcut: "⌘O", icon: "magnifyingglass") { library.quickOpen = .open },
            Command(title: "Subscribe to Feed…", shortcut: "⌥⌘U", icon: "dot.radiowaves.up.forward") { library.isAddingFeed = true },
            Command(title: "Check Feeds Now", shortcut: "⌘U", icon: "arrow.clockwise") { Task { await library.checkFeeds(all: true) } },
            Command(title: "Ask Your Library…", shortcut: "⌥⌘A", icon: "sparkles") { library.isAskingLibrary = true },
            Command(title: "Link Graph", icon: "point.3.connected.trianglepath.dotted") { library.isShowingGraph = true },
            Command(title: "New Notebook", icon: "book.pages") { library.newNotebook() },
            Command(title: "Concordance", icon: "textformat.abc") { library.isShowingConcordance = true },
            Command(title: "Statistics", icon: "chart.bar") { library.isShowingStatistics = true },
            Command(title: "Smart Rules…", icon: "wand.and.stars") { library.isEditingRules = true },
            Command(title: library.isShowingTagFilter ? "Hide Tag Filter" : "Show Tag Filter", shortcut: "⌥⌘T", icon: "tag") { library.isShowingTagFilter.toggle() },
            Command(title: "Show as List", icon: "list.bullet") { library.layout = .list },
            Command(title: "Show as Grid", icon: "square.grid.2x2") { library.layout = .grid },
            Command(title: "Show as Columns", icon: "tablecells") { library.layout = .table },
            Command(title: "Show as Board", icon: "rectangle.split.3x1") { library.layout = .board },
            Command(title: "Show as Calendar", icon: "calendar") { library.layout = .calendar },
            Command(title: "Save Workspace…", shortcut: "⌘S", icon: "rectangle.stack.badge.plus") { library.isSavingWorkspace = true },
            Command(title: "Manage Workspaces…", icon: "rectangle.stack") { library.isManagingWorkspaces = true },
            Command(title: "Manage Libraries…", icon: "books.vertical") { library.isManagingLibraries = true },
            Command(title: "Automatic Backups…", icon: "clock.arrow.circlepath") { library.isManagingBackups = true },
            Command(title: "Markdown Folder Mirror…", icon: "folder.badge.gearshape") { library.isManagingMirror = true },
            Command(title: "Export Everything…", shortcut: "⌥⌘E", icon: "square.and.arrow.up") { library.exportRequest = .everything },
            Command(title: "Restore from Backup…", icon: "arrow.uturn.backward") { library.isRestoring = true },
            Command(title: "Import Bookmarks or Links…", icon: "bookmark") { library.isImportingBookmarks = true },
            Command(title: "Import Feeds (OPML)…", icon: "dot.radiowaves.up.forward") { library.isImportingFeeds = true },
            Command(title: "Export Feeds (OPML)…", icon: "square.and.arrow.up") { library.exportRequest = .feeds },
            Command(title: "Import Notes Folder…", icon: "folder") { library.isImportingNotesFolder = true },
            Command(title: "Import from Evernote…", icon: "square.and.arrow.down") { library.isImportingEvernote = true },
            Command(title: "Import Mailbox…", icon: "envelope") { library.isImportingMailbox = true },
            Command(title: "Index Folder…", icon: "folder.badge.plus") { library.isChoosingFolderToIndex = true },
        ]
        let places: [(String, String, SidebarSelection)] = [
            ("Inbox", "tray.and.arrow.down", .inbox), ("All Items", "tray.full", .all), ("Favorites", "star", .favorites),
            ("Recents", "clock", .recents), ("Unfiled", "questionmark.folder", .unfiled), ("Tasks", "checklist", .tasks),
            ("Reminders", "bell", .reminders), ("Read Later", "book", .readLater), ("Timeline", "calendar", .timeline),
            ("Templates", "doc.on.doc", .templates), ("Trash", "trash", .trash),
        ]
        commands += places.map { name, icon, place in
            let key = PlaceCommands.places.firstIndex { $0.1 == place }.map { "⌘\($0 + 1)" } ?? ""
            return Command(title: "Go to " + name, shortcut: key, icon: icon) { library.sidebar = place }
        }
        commands += library.workspaces.map { workspace in
            Command(title: "Workspace: " + workspace.name, icon: "rectangle.stack") { library.open(workspace) }
        }
        let live = library.selectedItems.filter { !$0.isTrashed }
        if !live.isEmpty {
            let allFavorite = live.allSatisfy(\.isFavorite)
            let anyUnread = live.contains(where: \.isUnread)
            let allQueued = live.allSatisfy { $0.readLaterAt != nil }
            commands += [
                Command(title: allFavorite ? "Remove from Favorites" : "Add to Favorites", shortcut: "⌘D", icon: "star") {
                    library.setFavorite(live, !allFavorite)
                },
                Command(title: anyUnread ? "Mark as Read" : "Mark as Unread", shortcut: "⌥⌘R", icon: "circle.badge") {
                    library.setUnread(live, !anyUnread)
                },
                Command(title: allQueued ? "Remove from Read Later" : "Read Later", shortcut: "⌘R", icon: "book") {
                    library.setReadLater(live, !allQueued)
                },
                Command(title: "Add Tags…", shortcut: "⌘T", icon: "number") { library.taggingItems = live },
                Command(title: "Move to Category…", shortcut: "⌘G", icon: "folder") { library.quickOpen = .file(live) },
                Command(title: "Show in Category", shortcut: "⌥⌘G", icon: "folder.badge.questionmark") {
                    if let item = live.first { library.showInCategory(item) }
                },
                Command(title: "Duplicate", shortcut: "⌥⌘D", icon: "plus.square.on.square") { library.duplicate(live) },
                Command(title: "Rename…", icon: "pencil") { library.renamingItems = live },
                Command(title: "Lock", shortcut: "⌘J", icon: "lock") { library.lock(live) },
                Command(title: "Move to Trash", shortcut: "⌘⌫", icon: "trash") { library.moveToTrash(live) },
            ]
            if live.count == 1 {
                commands += [
                    Command(title: "Copy Item Link", shortcut: "⌥⌘L", icon: "link") { library.copyItemLink(live[0]) },
                    Command(title: "Copy Markdown Link", icon: "link") { library.copyMarkdownLink(live[0]) },
                    Command(title: "Print…", shortcut: "⌘P", icon: "printer") { library.printRequest = live[0] },
                ]
            }
        }
        return commands
    }
}

/// Naming a workspace, and the list of them to open, rename or delete.
struct WorkspaceSheets: ViewModifier {
    @Bindable var library: Library
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $library.isShowingPalette) { CommandPalette() }
            .sheet(isPresented: $library.isManagingWorkspaces) { WorkspacesView() }
            .alert("Save Workspace", isPresented: $library.isSavingWorkspace) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Save") {
                    library.saveWorkspace(named: name)
                    name = ""
                }
            } message: {
                Text("Keeps what the window shows: the place in the sidebar, the search, tags, view and the item open.")
            }
    }
}

struct WorkspacesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Workspace?
    @State private var draft = ""

    var body: some View {
        let _ = library.revision
        NavigationStack {
            List {
                if library.workspaces.isEmpty {
                    Text("Save a workspace from Go › Workspaces, or the command palette.").foregroundStyle(.secondary)
                }
                ForEach(library.workspaces) { workspace in
                    HStack {
                        Button(workspace.name) {
                            library.open(workspace)
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Rename…") {
                            draft = workspace.name
                            renaming = workspace
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) { library.deleteWorkspace(workspace) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename Workspace", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let renaming { library.renameWorkspace(renaming, to: draft) } }
            }
        }
        .sheetSize(minWidth: 420, minHeight: 320)
    }
}

/// *Workspaces* in the Go menu and the sidebar's ⋯ menu.
struct WorkspaceMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        Menu("Workspaces") {
            ForEach(library.workspaces) { workspace in
                Button(workspace.name) { library.open(workspace) }
            }
            if !library.workspaces.isEmpty { Divider() }
            Button("Save Workspace…") { library.isSavingWorkspace = true }
            Button("Manage Workspaces…") { library.isManagingWorkspaces = true }
        }
    }
}
