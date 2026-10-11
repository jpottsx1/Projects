import SwiftUI
import StashCore

struct AddLinkSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Web address", text: $address, prompt: Text("example.com/article"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(add)
                PasteButton(payloadType: URL.self) { urls in
                    guard let url = urls.first else { return }
                    Task { @MainActor in address = url.absoluteString }
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
        .frame(minWidth: 400, minHeight: 200)
    }

    private var url: URL? { WebAddress.url(from: address) }

    private func add() {
        guard let url else { return }
        library.addLink(url)
        dismiss()
    }
}
