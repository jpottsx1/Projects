import Foundation
import Observation
import UniformTypeIdentifiers
import StashCore

/// Reads what the other app is sharing, lets the person add a title, notes,
/// tags and a category, and leaves it all in the inbox for Stash to take in.
@MainActor
@Observable
final class ShareModel {
    /// Set by `SHARE_EXTENSION` in Config/Stash.xcconfig.
    #if SHARE_EXTENSION
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    enum Phase: Equatable {
        case loading
        case ready
        case nothingToSave
        case turnedOff
        case failed(String)
    }

    /// One thing being shared. Files are copied somewhere of our own as soon
    /// as they're read, because the sharing app's copy can vanish.
    struct Draft {
        var kind: SharedEntry.Kind
        var title: String
        var url: URL?
        var file: URL?
        var text: String = ""
    }

    private(set) var phase: Phase = .loading
    private(set) var drafts: [Draft] = []
    let categories: [SharedCategory]

    /// Edits the first item's title; with several, each keeps its own.
    var title = ""
    var notes = ""
    var tagsText = ""
    var categoryID: UUID?

    @ObservationIgnored private let context: NSExtensionContext?
    @ObservationIgnored private let inbox: SharedInbox?
    @ObservationIgnored private let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("StashShare-\(UUID().uuidString)", isDirectory: true)

    init(context: NSExtensionContext?) {
        self.context = context
        inbox = Self.isEnabled ? SharedInbox.forAppGroup() : nil
        categories = inbox?.categories() ?? []
        Task { await load() }
    }

    var summary: String {
        guard let first = drafts.first else { return "" }
        guard drafts.count == 1 else { return "\(drafts.count) items" }
        switch first.kind {
        case .link: return first.url.map { WebAddress.displayHost(of: $0) } ?? "Link"
        case .file: return first.file?.lastPathComponent ?? "File"
        case .note: return "Note"
        }
    }

    // MARK: - Reading what's shared

    private func load() async {
        guard Self.isEnabled, inbox != nil else {
            phase = .turnedOff
            return
        }
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        var links: [Draft] = []
        var files: [Draft] = []
        var texts: [String] = []
        var pageTitle: String?

        for item in items {
            if pageTitle == nil, let title = item.attributedContentText?.string ?? item.attributedTitle?.string,
               !title.isEmpty {
                pageTitle = title
            }
            for provider in item.attachments ?? [] {
                if let url = await loadURL(from: provider) {
                    if url.isFileURL {
                        if let copy = stage(url) { files.append(Draft(kind: .file, title: Self.title(of: copy), file: copy)) }
                    } else {
                        links.append(Draft(kind: .link, title: "", url: url))
                    }
                } else if let copy = await loadFile(from: provider) {
                    files.append(Draft(kind: .file, title: Self.title(of: copy), file: copy))
                } else if let text = await loadText(from: provider) {
                    // Some apps share an address as plain text.
                    if let url = WebAddress.url(from: text) {
                        links.append(Draft(kind: .link, title: "", url: url))
                    } else {
                        texts.append(text)
                    }
                }
            }
        }

        // Text alongside a link (a post's words, say) is kept as its notes;
        // text on its own becomes a note.
        let sharedText = texts.joined(separator: "\n\n")
        if var first = links.first {
            first.title = pageTitle ?? ""
            first.text = sharedText
            links[0] = first
        } else if !sharedText.isEmpty {
            let firstLine = sharedText.split(separator: "\n").first.map(String.init) ?? ""
            links.append(Draft(kind: .note, title: pageTitle ?? String(firstLine.prefix(80)), text: sharedText))
        }

        drafts = links + files
        title = drafts.first?.title ?? ""
        phase = drafts.isEmpty ? .nothingToSave : .ready
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        for type in [UTType.fileURL, .url] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let item = await loadItem(provider, type: type)
            if let url = item as? URL { return url }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let text = item as? String, let url = URL(string: text) { return url }
        }
        return nil
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        let item = await loadItem(provider, type: .plainText)
        if let text = item as? String { return text }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    /// A picture, PDF or other file handed over as data rather than as a
    /// file's address -- the way Photos shares.
    private func loadFile(from provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first(where: { $0.conforms(to: .data) && !$0.conforms(to: .plainText) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The file is deleted when this returns, so copy it now.
                let copy = url.flatMap { self.stageSynchronously($0, type: type) }
                continuation.resume(returning: copy)
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: UTType) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Copies of shared files

    private func stage(_ url: URL) -> URL? {
        stageSynchronously(url, type: nil)
    }

    /// Called from the item provider's own thread as well as ours: touches
    /// only the file system and a constant.
    nonisolated private func stageSynchronously(_ url: URL, type: UTType?) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            name += "." + ext
        }
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func title(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    // MARK: - Finishing

    func save() {
        guard let inbox else { return }
        let tags = TagName.split(tagsText)
        do {
            for (index, draft) in drafts.enumerated() {
                var entryText = draft.text
                if !notes.isEmpty { entryText = entryText.isEmpty ? notes : notes + "\n\n" + entryText }
                let entry = SharedEntry(
                    kind: draft.kind,
                    title: index == 0 ? title : draft.title,
                    url: draft.url?.absoluteString,
                    text: entryText,
                    tags: tags,
                    categoryID: categoryID)
                try inbox.add(entry, file: draft.file)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        cleanUp()
        ShareSignal.post()
        context?.completeRequest(returningItems: [], completionHandler: nil)
    }

    func cancel() {
        cleanUp()
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: staging)
    }
}
