import SwiftUI
import UniformTypeIdentifiers
import StashCore

/// Automatic backups: where, how often, how many to keep, and the ones there
/// are, to restore from.
struct AutoBackupView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AutoBackupSettings()
    @State private var backups: [URL] = []
    @State private var isChoosingFolder = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var restoring: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.folderName.isEmpty ? "None chosen" : settings.folderName)
                                .foregroundStyle(settings.folderName.isEmpty ? .secondary : .primary)
                            Button("Choose…") { isChoosingFolder = true }
                        }
                    }
                    Picker("Back Up", selection: binding(\.schedule)) {
                        Text("Never").tag(RuleSchedule.never.rawValue)
                        Text("Every Day").tag(RuleSchedule.daily.rawValue)
                        Text("Every Week").tag(RuleSchedule.weekly.rawValue)
                    }
                    Stepper("Keep the newest \(settings.keep)", value: binding(\.keep), in: 1...60)
                } footer: {
                    Text("The whole library, as Export Everything makes it, while Stash is open. Choose a folder in iCloud Drive, on another disk, or anywhere Time Machine doesn't already cover.")
                }
                Section {
                    Button(isWorking ? "Backing Up…" : "Back Up Now") {
                        Task {
                            isWorking = true
                            let succeeded = await library.backUpNow()
                            isWorking = false
                            reload()
                            if succeeded { message = "Backed up." }
                        }
                    }
                    .disabled(settings.bookmark == nil || isWorking)
                    if let last = settings.lastBackupAt {
                        Text("Last backed up \(last.formatted(.relative(presentation: .named))).")
                            .foregroundStyle(.secondary)
                    }
                    if let error = settings.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if !backups.isEmpty {
                    Section("Backups") {
                        ForEach(backups, id: \.self) { backup in
                            HStack {
                                Text(backup.deletingPathExtension().lastPathComponent)
                                Spacer()
                                Button("Restore…") { restoring = backup }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Automatic Backups")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize(minWidth: 460, minHeight: 480)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try library.chooseBackupFolder(url)
            } catch {
                message = error.localizedDescription
            }
            reload()
        }
        .confirmationDialog("Restore from “\(restoring?.deletingPathExtension().lastPathComponent ?? "")”?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") {
                guard let backup = restoring else { return }
                Task {
                    isWorking = true
                    do {
                        let summary = try await library.restoreAutomaticBackup(backup)
                        message = "Added \(summary.added) items; \(summary.skipped) were already here."
                    } catch {
                        message = error.localizedDescription
                    }
                    isWorking = false
                }
            }
        } message: {
            Text("Anything in the backup that isn't in the library is added back. Nothing here is changed or removed.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<AutoBackupSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: path] }, set: { value in
            settings[keyPath: path] = value
            var stored = library.autoBackupSettings
            stored[keyPath: path] = value
            library.autoBackupSettings = stored
        })
    }

    private func reload() {
        settings = library.autoBackupSettings
        backups = library.automaticBackups()
    }
}
