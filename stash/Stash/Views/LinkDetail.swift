import SwiftUI

struct LinkDetail: View {
    @Environment(Library.self) private var library
    @Bindable var item: Item
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = item.url {
                HStack {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        Task {
                            isRefreshing = true
                            await library.refreshPage(of: item)
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .help("Fetch the page again, for its latest summary and text to search")
                }
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Notes")
                .font(.headline)
            TextEditor(text: $item.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .padding()
        .onChange(of: item.body) { library.didEdit(item) }
    }
}
