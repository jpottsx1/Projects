import SwiftUI
import UniformTypeIdentifiers
import StashCore

/// Choosing the locking password, the first time anything is locked, or
/// typing it to open locked items.
struct PasswordSheet: View {
    @Environment(Library.self) private var library
    let request: PasswordRequest
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    private var isCreating: Bool { request.kind == .create }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    Text("Locked items are encrypted with a key kept under this password. Every device opens them with it.")
                        .font(.callout)
                }
                SecureField("Password", text: $password)
                    .focused($focused)
                    .onSubmit { if !isCreating { go() } }
                    .accessibilityIdentifier("lockPassword")
                if isCreating {
                    SecureField("Again", text: $confirmation)
                        .onSubmit(go)
                        .accessibilityIdentifier("lockPasswordAgain")
                    Label("If you forget it, locked items can’t be opened, by you or anyone else.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreating ? "Choose a Locking Password" : "Enter Locking Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { library.passwordRequest = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(isCreating ? "Lock" : "Unlock", action: go)
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
        .sheetSize(minWidth: 380, minHeight: isCreating ? 300 : 180)
        .onAppear { focused = true }
        .interactiveDismissDisabled(isWorking)
    }

    private func go() {
        guard !isWorking, !password.isEmpty else { return }
        if isCreating {
            guard password.count >= 6 else {
                error = "Use at least six characters."
                return
            }
            guard password == confirmation else {
                error = "The two passwords aren’t the same."
                return
            }
        }
        isWorking = true
        error = nil
        Task {
            if !(await library.answer(request, password: password)) {
                error = "That’s not the password."
                password = ""
            }
            isWorking = false
        }
    }
}

/// An encrypted item while it's unlocked: its text decrypted in memory and
/// saved back encrypted as it's edited, its file a decrypted copy that's
/// deleted when it locks again. Nothing decrypted is kept in the library.
struct SealedItemView: View {
    @Environment(Library.self) private var library
    let item: Item
    @State private var draft = ""
    @State private var select: Range<String.Index>?
    @State private var saving: Task<Void, Never>?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Label("Encrypted. It locks again when you leave Stash.", systemImage: "lock.open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            switch item.kind {
            case .note:
                editor
            case .document:
                document
                    .frame(maxHeight: .infinity)
                Divider()
                notes
            case .link:
                article
                    .frame(maxHeight: .infinity)
                Divider()
                notes
            }
        }
        .onAppear {
            draft = library.openSeals[item.uuid]?.body ?? ""
            loaded = true
        }
        .onChange(of: draft) {
            guard loaded else { return }
            saving?.cancel()
            saving = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                save()
            }
        }
        .onDisappear {
            saving?.cancel()
            save()
        }
    }

    private func save() {
        guard loaded, library.openSeals[item.uuid]?.body != draft else { return }
        library.updateSealed(item) { $0.body = draft }
    }

    private var editor: some View {
        LiveMarkdownEditor(text: $draft, select: $select, onCursorMoved: { _ in }, onSelectionChanged: { _ in },
                           pictureURL: { library.pictureURL($0, in: item) })
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").font(.headline)
            TextEditor(text: $draft)
                .frame(minHeight: 80, maxHeight: 160)
                .accessibilityIdentifier("sealedNotes")
        }
        .padding()
    }

    @ViewBuilder
    private var document: some View {
        if let url = library.localFile(for: item) {
            if item.contentType?.conforms(to: .audiovisualContent) == true {
                MediaPlayerView(item: item, url: url)
            } else if item.contentType?.conforms(to: .emailMessage) == true {
                EmailView(item: item, url: url)
            } else if item.isPDF {
                PDFKitView(url: url, controller: PDFController())
            } else {
                FileThumbnail(url: url).padding()
            }
        } else {
            ContentUnavailableView("Can’t Open the File", systemImage: "lock.doc",
                                   description: Text("It isn’t on this device yet, or couldn’t be decrypted."))
        }
    }

    @ViewBuilder
    private var article: some View {
        let contents = library.openSeals[item.uuid]
        if let data = contents?.article, let article = try? JSONDecoder().decode(Article.self, from: data) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title).font(.title2.bold())
                    MarkdownView(text: HTMLMarkdown.convert(article.html))
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            VStack(spacing: 12) {
                if let summary = contents?.summary, !summary.isEmpty { Text(summary) }
                if let url = item.url { Link("Open \(url.host() ?? "Website")", destination: url) }
            }
            .padding()
        }
    }
}
