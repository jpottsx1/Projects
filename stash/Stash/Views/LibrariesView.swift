import SwiftUI

/// The libraries, to switch between: for the sidebar's ⋯ menu and, on a
/// Mac, the Library menu.
struct LibraryMenuItems: View {
    @Environment(Library.self) private var library
    var withShortcuts = false

    var body: some View {
        let store = StashStore.shared
        ForEach(Array(store.libraries.enumerated()), id: \.element.id) { position, info in
            let button = Button {
                store.switchTo(info)
            } label: {
                if info == store.current {
                    Label(info.name, systemImage: "checkmark")
                } else {
                    Text(info.name)
                }
            }
            if withShortcuts, position < 9 {
                button.keyboardShortcut(KeyEquivalent(Character(String(position + 1))), modifiers: [.command, .control])
            } else {
                button
            }
        }
        Divider()
        Button("Manage Libraries…") { library.isManagingLibraries = true }
    }
}

/// Making, renaming, opening and deleting libraries.
struct LibrariesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var deleting: LibraryInfo?

    var body: some View {
        let store = StashStore.shared
        NavigationStack {
            Form {
                Section {
                    ForEach(store.libraries) { info in
                        LibraryRow(info: info, isCurrent: info == store.current) { deleting = info }
                    }
                } footer: {
                    Text("Each library has its own items, categories, tags, lists and feeds. Only the main library syncs with iCloud and appears in Spotlight, reminders and widgets; the others stay on this device.")
                }
                Section("New Library") {
                    TextField("Name", text: $newName)
                        .accessibilityIdentifier("newLibraryName")
                        .onSubmit(make)
                    Button("Make and Open", action: make)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Libraries")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetSize(minWidth: 460, minHeight: 420)
        .confirmationDialog("Delete the library “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Library", role: .destructive) {
                if let deleting { StashStore.shared.delete(deleting) }
            }
        } message: {
            Text("Everything in it is deleted from this device, and can’t be got back except from a backup.")
        }
    }

    private func make() {
        guard let info = StashStore.shared.createLibrary(named: newName) else { return }
        newName = ""
        dismiss()
        StashStore.shared.switchTo(info)
    }
}

private struct LibraryRow: View {
    let info: LibraryInfo
    let isCurrent: Bool
    let onDelete: () -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: info.isMain ? "books.vertical.fill" : "books.vertical")
                .foregroundStyle(.tint)
            TextField("Name", text: $name)
                .onSubmit { StashStore.shared.rename(info, to: name) }
                .onAppear { name = info.name }
            if info.isMain {
                Text("Main").font(.caption).foregroundStyle(.secondary)
            }
            if isCurrent {
                Text("Open").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Open") { StashStore.shared.switchTo(info) }
                    .buttonStyle(.borderless)
            }
            if !info.isMain {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }
}
