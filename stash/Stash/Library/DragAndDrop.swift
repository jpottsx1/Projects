import Foundation
import UniformTypeIdentifiers
import StashCore

/// Dragging items out to other apps, and things in from them.
extension Library {
    /// What can be dropped on the list.
    static let droppableTypes: [UTType] = [.emailMessage, .fileURL, .url, .image, .plainText]

    /// An item, dragged out: a note as its text, a link as its address, a
    /// document as its file.
    func itemProvider(for item: Item) -> NSItemProvider? {
        guard !isHidden(item), !item.isTrashed else { return nil }
        let provider: NSItemProvider
        switch item.kind {
        case .note:
            let text = item.isSealed ? (openSeals[item.uuid]?.body ?? "") : item.body
            provider = NSItemProvider(object: ("# " + item.displayTitle + "\n\n" + text) as NSString)
        case .link:
            guard let url = item.url else { return nil }
            provider = NSItemProvider(object: url as NSURL)
        case .document:
            guard let file = localFile(for: item), let made = NSItemProvider(contentsOf: file) else { return nil }
            provider = made
        }
        provider.suggestedName = item.displayTitle
        return provider
    }

    /// Whatever was dropped: files and pictures come in as documents,
    /// messages from Mail as emails, web addresses as links, text as a note.
    func importDropped(_ providers: [NSItemProvider]) async {
        let mail = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.emailMessage.identifier) }
        if !mail.isEmpty { await importEmailProviders(mail) }
        for provider in providers where !mail.contains(provider) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await Self.load(URL.self, from: provider), url.isFileURL {
                importFiles([url])
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await Self.load(URL.self, from: provider), let web = WebAddress.url(from: url.absoluteString) {
                addLink(web)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let file = await Self.copyFile(of: .image, from: provider) {
                importFiles([file])
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await Self.load(String.self, from: provider) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !trimmed.contains(where: \.isWhitespace), let web = WebAddress.url(from: trimmed) {
                    addLink(web)
                } else {
                    let firstLine = trimmed.prefix { $0 != "\n" }
                    newNote(titled: String(firstLine.prefix(60)), text: trimmed)
                }
            }
        }
    }

    private static func load<T: _ObjectiveCBridgeable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: T.self) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// The dropped thing as a file of its own, copied before the provider's goes.
    private static func copyFile(of type: UTType, from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let name = provider.suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent
                let destination = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
