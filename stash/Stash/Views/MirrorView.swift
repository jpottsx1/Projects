import SwiftUI
import UniformTypeIdentifiers

/// The Markdown folder mirror: where, on or off, and when it last ran.
struct MirrorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MirrorSettings()
    @State private var isChoosing = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.folderName.isEmpty ? "None chosen" : settings.folderName)
                                .foregroundStyle(settings.folderName.isEmpty ? .secondary : .primary)
                            Button("Choose…") { isChoosing = true }
                        }
                    }
                    Toggle("Keep It in Step", isOn: Binding(get: { settings.isOn }, set: { on in
                        settings.isOn = on
                        var stored = library.mirrorSettings
                        stored.isOn = on
                        library.mirrorSettings = stored
                        if on { library.scheduleMirror() }
                    }))
                    .disabled(settings.bookmark == nil)
                } footer: {
                    Text("Notes and links as Markdown files, documents as themselves, in a folder for each category, with [[links]] as they are, so Obsidian or any editor can read your library. Changes are written a few seconds after you make them. It's one way: changes made in the folder aren't read back. Locked items and saved web pages stay out. Use an empty folder: files Stash didn't write there are left alone.")
                }
                Section {
                    Button(isWorking ? "Writing…" : "Mirror Now") {
                        Task {
                            isWorking = true
                            await library.mirrorNow()
                            isWorking = false
                            settings = library.mirrorSettings
                        }
                    }
                    .disabled(settings.bookmark == nil || isWorking)
                    if let last = settings.lastMirroredAt {
                        Text("Last written \(last.formatted(.relative(presentation: .named))).").foregroundStyle(.secondary)
                    }
                    if let error = settings.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Markdown Folder Mirror")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize(minWidth: 460, minHeight: 380)
        .onAppear { settings = library.mirrorSettings }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            try? library.chooseMirrorFolder(url)
            settings = library.mirrorSettings
        }
    }
}
