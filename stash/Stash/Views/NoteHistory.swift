import SwiftUI

/// A note's earlier versions, newest first: look at one, put it back.
struct NoteHistoryView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: Item

    var body: some View {
        NavigationStack {
            List {
                let versions = (item.versions ?? []).sorted { $0.savedAt > $1.savedAt }
                if versions.isEmpty {
                    ContentUnavailableView("No Earlier Versions", systemImage: "clock.arrow.circlepath",
                                           description: Text("A version is kept each time you finish editing the note."))
                }
                ForEach(versions) { version in
                    NavigationLink {
                        VersionDetail(version: version) { dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.savedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(version.body.prefix(120))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .contextMenu {
                        Button("Delete Version", role: .destructive) { library.delete(version) }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetSize(minWidth: 460, minHeight: 480)
    }
}

private struct VersionDetail: View {
    @Environment(Library.self) private var library
    let version: NoteVersion
    let onRestore: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !version.title.isEmpty, version.title != version.item?.title {
                    Text("Titled “\(version.title)” then")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MarkdownView(text: version.body)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(version.savedAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restore This Version") {
                    library.restore(version)
                    onRestore()
                }
            }
        }
    }
}
