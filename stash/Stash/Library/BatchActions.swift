import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// Formats an item can be turned into, as a new document beside it.
enum ConversionFormat: String, CaseIterable, Identifiable {
    case pdf, markdown, plainText

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .markdown: "md"
        case .plainText: "txt"
        }
    }
}

/// Renaming and converting many items at once, as DEVONthink does.
extension Library {
    /// Gives the items new titles, and points `[[links]]` at them.
    func rename(_ items: [Item], mode: BatchRename.Mode) {
        let live = items.filter { !$0.isTrashed }
        let titles = BatchRename.titles(for: live.map(Self.renameSource), mode: mode)
        for (item, title) in zip(live, titles) where title != item.title {
            let old = item.title
            item.title = title
            didEdit(item)
            rename(item, from: old)
        }
        save()
        revision += 1
    }

    static func renameSource(_ item: Item) -> BatchRename.Source {
        BatchRename.Source(title: item.displayTitle, created: item.createdAt, kind: item.kind.rawValue.capitalized)
    }

    /// Whether an item can be converted: notes and links (locked ones only
    /// once unlocked, so nothing decrypted is written without asking).
    static func canConvert(_ item: Item) -> Bool {
        item.kind != .document && !item.isLocked && !item.isTrashed
    }

    /// Makes a document of each item in the format, filed beside it and
    /// linked from it; the items themselves stay as they are. Gives the new
    /// documents.
    @discardableResult
    func convert(_ items: [Item], to format: ConversionFormat) async -> [Item] {
        var made: [Item] = []
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for item in items where Self.canConvert(item) {
            let file: URL?
            switch format {
            case .pdf:
                file = await ItemPrinter().pdf(of: item, in: self)
            case .markdown, .plainText:
                let url = folder.appendingPathComponent(ExportNaming.safe(item.displayTitle) + "." + format.fileExtension)
                let text = format == .markdown ? Self.markdown(of: item) : Self.plainText(of: item)
                file = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
            }
            guard let file, isAlive(item) else {
                importError = "“\(item.displayTitle)” couldn’t be converted to \(format.name)."
                continue
            }
            let document = Item(kind: .document, title: item.displayTitle)
            guard let path = try? files.importFile(at: file, for: document.uuid) else { continue }
            document.storedFilePath = path
            document.contentTypeIdentifier = UTType(filenameExtension: format.fileExtension)?.identifier
            document.fileData = syncableContents(of: document)
            context.insert(document)
            document.category = item.category
            document.tags = item.tags
            link(item, to: document)
            reindex(document)
            made.append(document)
        }
        save()
        revision += 1
        if let last = made.last { selection = last }
        Task {
            for document in made where isAlive(document) {
                await fillContentHash(of: document)
                await fillThumbnail(of: document)
                await extractText(from: document)
            }
        }
        return made
    }

    /// A note's own Markdown; a link's article (or summary) as Markdown,
    /// with where it's from, then its notes.
    static func markdown(of item: Item, bracketingAddress: Bool = true) -> String {
        switch item.kind {
        case .note:
            return "# \(item.displayTitle)\n\n" + item.body
        case .link:
            var parts = ["# \(item.displayTitle)"]
            if let url = item.urlString { parts.append(bracketingAddress ? "<\(url)>" : url) }
            if let article = item.article {
                parts.append(HTMLMarkdown.convert(article.html))
            } else if !item.summary.isEmpty {
                parts.append(item.summary)
            }
            if !item.body.isEmpty { parts.append("## Notes\n\n" + item.body) }
            return parts.joined(separator: "\n\n")
        case .document:
            return item.body
        }
    }

    static func plainText(of item: Item) -> String {
        MarkdownStyling.plainLines(markdown(of: item, bracketingAddress: false))
    }
}
