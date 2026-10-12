import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// Email kept as DEVONthink keeps it: each message an .eml document,
/// titled with its subject and dated when it was sent, searchable by who
/// it's from and to as well as what it says.
extension Library {
    /// Reads a message's headers and text into its item.
    func readEmail(_ item: Item, at url: URL) async {
        guard let message = await Task.detached(priority: .utility, operation: {
            (try? Data(contentsOf: url)).flatMap(MIMEMessage.init)
        }).value, isAlive(item) else { return }
        apply(message, to: item)
        reindex(item)
        save()
    }

    private func apply(_ message: MIMEMessage, to item: Item) {
        let fileTitle = (item.storedFilePath.map { ($0 as NSString).lastPathComponent } ?? "") as NSString
        // A title still the file's name is replaced by the subject.
        if item.title.isEmpty || item.title == fileTitle.deletingPathExtension, !message.subject.isEmpty {
            item.title = message.subject
        }
        if let date = message.date { item.createdAt = date }
        item.messageID = message.messageID ?? ""
        item.extractedText = Self.searchableText(of: message)
    }

    static func searchableText(of message: MIMEMessage) -> String {
        func people(_ addresses: [MIMEMessage.Address]) -> String {
            addresses.map { $0.name.isEmpty ? $0.email : "\($0.name) \($0.email)" }.joined(separator: ", ")
        }
        let lines = ["From: " + people(message.from), "To: " + people(message.to + message.cc), "Subject: " + message.subject,
                     "", message.plainText] + message.attachments.map { "Attachment: " + $0.fileName }
        return String(lines.joined(separator: "\n").prefix(TextExtractor.maxLength))
    }

    /// Whether a message with this Message-ID is in the library already.
    func hasMessage(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.messageID == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// An .mbox file, or a mailbox exported from Mail (a folder with an
    /// `mbox` file inside): each message becomes an email in a category
    /// named after the mailbox. Messages already here are skipped.
    func importMailbox(_ url: URL) async -> ImportSummary {
        var summary = ImportSummary()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var file = url
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            file = url.appendingPathComponent("mbox")
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            summary.failed.append(url.lastPathComponent)
            return summary
        }
        let messages = await Task.detached(priority: .userInitiated) { Mbox.messages(in: data) }.value
        let category = importCategory(named: url.deletingPathExtension().lastPathComponent, in: nil)
        summary.categoryName = category?.path
        var added: [Item] = []
        for (number, raw) in messages.enumerated() {
            guard let message = MIMEMessage(raw) else {
                summary.failed.append("message \(number + 1)")
                continue
            }
            if let id = message.messageID, hasMessage(id) { continue }
            let name = ExportNaming.safe(message.subject.isEmpty ? "Message \(number + 1)" : message.subject)
            guard let item = addDocument(data: raw, named: name + ".eml", in: category) else {
                summary.failed.append(name)
                continue
            }
            item.contentTypeIdentifier = UTType.emailMessage.identifier
            apply(message, to: item)
            item.modifiedAt = item.createdAt
            reindex(item)
            added.append(item)
            summary.emails += 1
            if number % 50 == 49 { save(); await Task.yield() }
        }
        save()
        revision += 1
        if let category { sidebar = .category(category) }
        return summary
    }

    /// Takes an email's attachment into the library as a document of its
    /// own, linked from the email, and shows it.
    func saveAttachment(_ attachment: MIMEMessage.Attachment, of email: Item) {
        guard let document = addDocument(data: attachment.data, named: attachment.fileName, in: email.category) else { return }
        document.inInbox = email.category == nil
        link(email, to: document)
        save()
        selection = document
        Task {
            await fillContentHash(of: document)
            await fillThumbnail(of: document)
            await extractText(from: document)
        }
    }
}

extension Library {
    /// Messages dragged in from Mail, which promises each as an .eml file.
    func importEmailProviders(_ providers: [NSItemProvider]) async {
        var files: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.emailMessage.identifier) {
            let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let copied: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.emailMessage.identifier) { url, _ in
                    // Gone once this returns: copy it now.
                    guard let url else { return continuation.resume(returning: nil) }
                    let name = url.pathExtension.isEmpty ? url.lastPathComponent + ".eml" : url.lastPathComponent
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
            if let copied { files.append(copied) }
        }
        importFiles(files)
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}
