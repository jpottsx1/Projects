import SwiftUI
import StashCore

struct AddLinkSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @AppStorage("addLinkSaveAs") private var saveAs = PageFormat.link.rawValue
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Web address", text: $address, prompt: Text("example.com/article"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(add)
                PasteButton(payloadType: URL.self) { urls in
                    guard let url = urls.first else { return }
                    Task { @MainActor in address = url.absoluteString }
                }
                Picker("Also Save As", selection: $saveAs) {
                    ForEach(PageFormat.allCases) { Text($0 == .link ? "Nothing Else" : $0.name).tag($0.rawValue) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(url == nil)
                }
            }
        }
        .sheetSize(minWidth: 400, minHeight: 240)
        .onAppear { focused = true }
    }

    private var url: URL? { WebAddress.url(from: address) }

    private func add() {
        guard let url else { return }
        library.addLink(url, savingAs: PageFormat(rawValue: saveAs) ?? .link)
        dismiss()
    }
}
