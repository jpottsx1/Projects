import SwiftUI
import StashCore

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Stash")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }
                    }
                    if model.phase == .ready {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { model.save() }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .turnedOff:
            ContentUnavailableView(
                "Sharing Isn’t Turned On", systemImage: "square.and.arrow.down",
                description: Text("Turn it on with SHARE_EXTENSION in Config/Stash.xcconfig, then build Stash again. The README explains how."))
        case .nothingToSave:
            ContentUnavailableView(
                "Nothing Stash Can Save", systemImage: "questionmark.square.dashed",
                description: Text("Stash saves web links, files, pictures and text."))
        case .failed(let message):
            ContentUnavailableView("Couldn’t Save", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .ready:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Title", text: $model.title)
                LabeledContent("Saving", value: model.summary)
            }
            Section("Notes") {
                TextField("Optional", text: $model.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                TextField("Tags, separated by commas", text: $model.tagsText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if let chosen = model.chosenCategory {
                    HStack {
                        Label(chosen, systemImage: "folder")
                        Spacer()
                        Button {
                            model.categoryID = nil
                            model.newCategory = nil
                        } label: {
                            Label("No Category", systemImage: "xmark.circle.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                TextField("Find or make a category", text: $model.categorySearch)
                    .autocorrectionDisabled()
                ForEach(model.matchingCategories) { category in
                    Button(category.path) {
                        model.categoryID = category.id
                        model.newCategory = nil
                        model.categorySearch = ""
                    }
                }
                let typed = model.categorySearch.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty, !model.categories.contains(where: { $0.path.caseInsensitiveCompare(typed) == .orderedSame }) {
                    Button("Make “\(typed)”") {
                        model.newCategory = typed
                        model.categoryID = nil
                        model.categorySearch = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
