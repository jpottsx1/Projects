import SwiftUI
import StashCore

/// Names a smart filter and says what it shows. A new one when `filter` is nil.
struct SmartFilterEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let filter: SmartFilter?
    var onSave: () -> Void = {}
    @State private var name: String
    @State private var query: String

    init(filter: SmartFilter?, query: String = "", onSave: @escaping () -> Void = {}) {
        self.filter = filter
        self.onSave = onSave
        _name = State(initialValue: filter?.name ?? "")
        _query = State(initialValue: filter?.query ?? query)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Search", text: $query, axis: .vertical)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("""
                        Words to find, and any of these: \
                        "exact phrase", word OR other, -leave-out, #tag, -#tag, \
                        kind:note, kind:link, kind:pdf, kind:image, in:Category, \
                        is:favorite, is:untagged, after:7d, before:2026-01-01.
                        """)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(filter == nil ? "New Smart Filter" : "Edit Smart Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || SearchQuery(query).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private func save() {
        if let filter {
            library.update(filter, name: name, query: query)
        } else if let made = library.newSmartFilter(named: name, query: query) {
            library.sidebar = .smartFilter(made)
        }
        onSave()
        dismiss()
    }
}
